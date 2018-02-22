FROM nvidia/cuda:9.1-cudnn7-devel-ubuntu16.04 

RUN echo "deb http://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1604/x86_64 /" > /etc/apt/sources.list.d/nvidia-ml.list

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cuda-command-line-tools-9-0 \
        cuda-cublas-dev-9-0 \
        cuda-cudart-dev-9-0 \
        cuda-cufft-dev-9-0 \
        cuda-curand-dev-9-0 \
        cuda-cusolver-dev-9-0 \
        cuda-cusparse-dev-9-0 \
        curl \
        git \
        libcurl3-dev \
        libfreetype6-dev \
        libpng12-dev \
        libzmq3-dev \
        pkg-config \
        python-dev \
        rsync \
        software-properties-common \
        unzip \
        zip \
        zlib1g-dev \
        wget \
        && \
    rm -rf /var/lib/apt/lists/* && \
    find /usr/local/cuda-9.0/lib64/ -type f -name 'lib*_static.a' -not -name 'libcudart_static.a' -delete && \
    rm /usr/lib/x86_64-linux-gnu/libcudnn_static_v7.a



ENV PYTHON_VERSION=3.6
RUN curl -o ~/miniconda.sh -O  https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh  && \
     chmod +x ~/miniconda.sh && \
     ~/miniconda.sh -b -p /opt/conda && \     
     rm ~/miniconda.sh && \
#     /opt/conda/bin/conda install conda-build && \
     /opt/conda/bin/conda create -y --name riptide-py$PYTHON_VERSION python=$PYTHON_VERSION numpy pyyaml scipy ipython mkl&& \
     /opt/conda/bin/conda clean -ya 
ENV PATH /opt/conda/envs/riptide-py$PYTHON_VERSION/bin:$PATH
RUN conda install numpy pyyaml mkl setuptools cmake cffi

RUN pip --no-cache-dir install \
        ipykernel \
        jupyter \
        matplotlib \
        numpy \
        scipy \
        sklearn \
        pandas \
        && \
    python -m ipykernel.kernelspec

# install tensorflow

# Set up Bazel.

# Running bazel inside a `docker build` command causes trouble, cf:
#   https://github.com/bazelbuild/bazel/issues/134
# The easiest solution is to set up a bazelrc file forcing --batch.
RUN echo "startup --batch" >>/etc/bazel.bazelrc
# Similarly, we need to workaround sandboxing issues:
#   https://github.com/bazelbuild/bazel/issues/418
RUN echo "build --spawn_strategy=standalone --genrule_strategy=standalone" \
    >>/etc/bazel.bazelrc
# Install the most recent bazel release.
ENV BAZEL_VERSION 0.8.0
WORKDIR /
RUN mkdir /bazel && \
    cd /bazel && \
    curl -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.133 Safari/537.36" -fSsL -O https://github.com/bazelbuild/bazel/releases/download/$BAZEL_VERSION/bazel-$BAZEL_VERSION-installer-linux-x86_64.sh && \
    curl -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/57.0.2987.133 Safari/537.36" -fSsL -o /bazel/LICENSE.txt https://raw.githubusercontent.com/bazelbuild/bazel/master/LICENSE && \
    chmod +x bazel-*.sh && \
    ./bazel-$BAZEL_VERSION-installer-linux-x86_64.sh && \
    cd / && \
    rm -f /bazel/bazel-$BAZEL_VERSION-installer-linux-x86_64.sh

# Download and build TensorFlow.
COPY tensorflow /tensorflow
WORKDIR /tensorflow

# Configure the build for our CUDA configuration.
ENV CI_BUILD_PYTHON python
ENV LD_LIBRARY_PATH /usr/local/cuda/extras/CUPTI/lib64:$LD_LIBRARY_PATH
ENV TF_NEED_CUDA 1
ENV TF_CUDA_COMPUTE_CAPABILITIES=6.1
ENV TF_CUDA_VERSION=9.1
ENV TF_CUDNN_VERSION=7
ENV TF_ENABLE_XLA=1

RUN ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH} \
    tensorflow/tools/ci_build/builds/configured GPU \
    bazel build -c opt --config=cuda --config=mkl\
	--cxxopt="-D_GLIBCXX_USE_CXX11_ABI=0" \
        tensorflow/tools/pip_package:build_pip_package && \
    rm /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    bazel-bin/tensorflow/tools/pip_package/build_pip_package /tmp/pip && \
    pip --no-cache-dir install --upgrade /tmp/pip/tensorflow-*.whl && \
    rm -rf /tmp/pip && \
    rm -rf /root/.cache
# Clean up pip wheel and Bazel cache when done.

# Halide setup

# install pybind
WORKDIR /
RUN git clone https://github.com/pybind/pybind11.git
WORKDIR /pybind11
RUN python setup.py build
RUN python setup.py install
ENV PYBIND11_PATH /pybind11
ENV CPLUS_INCLUDE_PATH /pybind11/include

# install halide
WORKDIR /
RUN ln -s /usr/bin/llvm-config-4.0 /usr/bin/llvm-config
RUN ln -s /usr/bin/clang-4.0 /usr/bin/clang
#RUN git clone https://github.com/halide/Halide.git
COPY Halide /Halide
WORKDIR /Halide

RUN sed -i 's/-lpthread/-lpthread -ltinfo/' Makefile 
RUN make distrib -j8
RUN make install
#
ENV HALIDE_DISTRIB_PATH /Halide/distrib

# set up python bindings
RUN ln -s /usr/lib/x86_64-linux-gnu/libboost_python-py35.so /usr/lib/x86_64-linux-gnu/libboost_python3.so
WORKDIR /Halide/python_bindings
#COPY python_bindings_makefile.patch Makefile.patch
#RUN patch -p2 < Makefile.patch
RUN make -j8
ENV PYTHONPATH /Halide/python_bindings/bin:$PYTHONPATH

# install tvm
COPY tvm /tvm
COPY docker/tvm_config.mk /tvm/make/config.mk
WORKDIR /tvm
RUN make -j8
WORKDIR /tvm/python
RUN python setup.py install
WORKDIR /tvm/topi/python
RUN python setup.py install

RUN pip --no-cache-dir install \
        Pillow \
        ipykernel \
        mixpanel \
        graphviz \
        pydot \
        pydot_ng \
        pyyaml \
        scikit-learn \
        scikit-image \
        gensim \
        cffi \
        opencv-python \
        bitfinex \
        gym \
        gym[atari] \
        flask \
        requests_ntlm \
        docopt \
        tensorboard \
        jupyterlab \
        && \
    python -m ipykernel.kernelspec

# Set up our notebook config.
COPY docker/jupyter_notebook_config.py /root/.jupyter/

# Jupyter has issues with being run directly:
#   https://github.com/ipython/ipython/issues/7062
# We just add a little wrapper script.
COPY docker/run_jupyter.sh /

# Set up some convenience stuff
COPY docker/.vimrc /root
COPY docker/.gitconfig /root

ENV DISPLAY 0

EXPOSE 8888

WORKDIR /workspace
WORKDIR /root
# set utf-8 encoding, weird that we have to do this haha
ENV LC_ALL "C.UTF-8"
# set up philly environment
ENV PHILLY_USERNAME matthaip
ENV PHILLY_PASSWORD Messi is gr8
ENV PHILLY_CLUSTER gcr
ENV PHILLY_VC msrlabs
ENV USER jwfromm

RUN chmod -R a+w /workspace

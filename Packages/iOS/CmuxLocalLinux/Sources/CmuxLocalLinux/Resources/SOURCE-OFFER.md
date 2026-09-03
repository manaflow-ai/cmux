# Corresponding source offer

This cmux iOS build includes the iSH user-mode x86 kernel, the cmux iSH bridge,
libarchive, and an Alpine Linux root filesystem. You can obtain the corresponding source
from the public repositories and pinned revisions below:

- cmux: <https://github.com/manaflow-ai/cmux>
- iSH fork: <https://github.com/manaflow-ai/ish>, submodule revision
  `efd2fa7a2b5a46d601fb0b9e667032591c7ad54d`
- Alpine root filesystem image: <https://github.com/manaflow-ai/ish/releases>,
  baked by `scripts/bake-ish-rootfs.sh` in the cmux repository
- Alpine package sources: <https://git.alpinelinux.org/aports>
- libarchive: the revision in `vendor/ish/deps/libarchive` in the iSH source

The cmux repository contains the exact bridge sources, build scripts, rootfs
manifest, and license texts used to produce the app artifact. For at least
three years after distribution, written requests for a source archive may be
sent to <opensource@manaflow.ai> with the app version and build identifier.

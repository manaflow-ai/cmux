# Building the native Apple artifact

The repository keeps Rust and the Swift adapter, with generated bindings and
binaries excluded from Git. Submit the following through the controller job
system on a Mac worker:

```sh
python3 services/transport-v3/ops/apple/build.py \
  --package Packages/Shared/CmuxV3Transport \
  --target-dir /tmp/cmux-v3-apple \
  --release
```

The command builds all four Apple slices with Rust 1.98.1, generates UniFFI
Swift bindings from that same library, and emits one XCFramework in the package
directory. Build this artifact before Swift package resolution. Missing native
artifacts are build errors; there is no placeholder transport. Generated files
and the XCFramework are gitignored. Signing belongs to app distribution.

`scripts/ensure-transport-v3.sh` is the build-worker entrypoint used by setup,
iOS reload and the TestFlight workflow. It reuses artifacts only when source,
toolchain settings and every generated file hash match the receipt. Generation
is serialized within the package directory. No iroh fallback is provided.

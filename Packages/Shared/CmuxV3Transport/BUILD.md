# Building the native Apple artifact

The repository keeps Rust and generated Swift source, not a large checked-in
XCFramework. On a leased Mac, run:

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

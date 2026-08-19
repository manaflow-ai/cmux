# Vendored IrohLib bindings

`IrohLib.swift` is the unmodified uniffi-generated Swift binding from
[n0-computer/iroh-ffi v1.1.0](https://github.com/n0-computer/iroh-ffi/tree/v1.1.0/IrohLib/Sources/IrohLib).
It imports the `Iroh` clang module provided by `IrohFFI.xcframework`, which
`scripts/ensure-iroh-xcframework.sh` materializes at the repo root from the
same upstream release's checksummed binaries (rewrapped framework-style so
its module map cannot collide with GhosttyKit's in the shared products
include directory).

There is no fork: binaries and bindings are byte-for-byte upstream, pinned to
one tag. To update, bump the version and checksum in
`scripts/ensure-iroh-xcframework.sh`, replace this file's `IrohLib.swift`
from the new tag, and delete `IrohFFI.xcframework` so the script refetches.

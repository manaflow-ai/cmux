# cmux-iroh

Minimal blocking C FFI over [iroh](https://www.iroh.computer/), the substrate
for the cmux iOS-to-Mac transport (`plans/feat-ios-iroh/DESIGN.md`). Graduated
from `experiments/iroh-swift-ffi-spike` with two production changes: `bind`
takes a caller-provided 32-byte Ed25519 secret key (key custody lives in
Swift/Keychain, never inside Rust), and every fallible call reports a stable
`CmuxIrohErrorKind` next to the human-readable message.

## Packaging

`scripts/ensure-cmux-iroh.sh` builds this crate into a gitignored
`CmuxIrohFFI.xcframework` symlinked at the repo root (macOS arm64+x86_64, iOS
device arm64, iOS simulator arm64), content-hash cached under
`~/.cache/cmux/cmux-iroh`, mirroring `scripts/ensure-ghosttykit.sh`. The
xcframework is a pure binary (no headers); `Packages/Shared/CmuxIrohFFI` wraps it in
a SwiftPM package that owns the C header and the `CmuxIrohFFI` module. The
macOS app links that package product directly (`cmux.xcodeproj`); the iOS app
links it through `Packages/CmuxMobileTransport`.

## Pins

- iroh `=1.0.0-rc.1`: newest published iroh as of 2026-06-11 and the version
  the spike proved end to end. The 1.0 rc line is the stable-core API
  (Endpoint, connect/accept, streams). Bump deliberately: update
  `Cargo.toml` + `Cargo.lock`, re-run `cargo test`, and re-verify the relay
  map note in the design doc (rc endpoints currently home on n0's canary
  relays).
- Rust toolchain pinned in `rust-toolchain.toml` (rustup picks it up
  automatically inside this directory, including the four Apple targets).

## Header

The C header is hand-maintained (the spike's approach) at
`Packages/Shared/CmuxIrohFFI/Sources/CmuxIrohFFI/include/cmux_iroh_ffi.h`: the
surface is small and deliberate, and avoiding cbindgen keeps the build
toolchain-free. Any change to the `extern "C"` surface in `src/lib.rs` must
update that header in the same commit.

## Tests

```bash
cd Native/cmux-iroh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

The FFI seam tests drive the extern "C" functions exactly as Swift would (raw
pointers, error buffers, error kinds). The loopback roundtrip binds two
endpoints with relays disabled and dials by EndpointId + direct addrs, so the
suite is hermetic (local UDP only, no relay/discovery dependency).

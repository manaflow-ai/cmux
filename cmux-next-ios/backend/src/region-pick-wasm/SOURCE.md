# region_pick.wasm (generated)

The Rust crate `cmux-next-ios/rust/crates/cmux-region-pick` (RFD 0142 O2, the hub's central relay region pick)
built for `wasm32-unknown-unknown` with no bindgen: plain `extern "C"` exports over one `f64` buffer
(`src/wasm.rs`), loaded by `../region-pick.ts`. No imports. Rebuild after any change to the crate, from
`cmux-next-ios/rust`:

```sh
RUSTFLAGS="-C strip=symbols" cargo rustc -p cmux-region-pick --release --target wasm32-unknown-unknown --crate-type cdylib
cp target/wasm32-unknown-unknown/release/cmux_region_pick.wasm ../backend/src/region-pick-wasm/region_pick.wasm
```

`test/region-pick.test.ts` runs this file on the crate's own cases, so a stale copy fails there.

2026-11-25: built on gcp-agent-lane-12 (rustc 1.95.0) from lane/o2-central-region-pick: ABI 1, 6475 bytes,
sha256 8ecd702e4735d6f94deafd885f59a0c977a6a56fd4b0e4286ea01201faf21055.

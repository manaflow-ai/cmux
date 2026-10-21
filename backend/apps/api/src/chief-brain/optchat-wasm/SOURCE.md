# optchat-wasm (generated)

The wasm-bindgen output of the Rust OptChat core (`Native/OptChat/optchat-core`, bindings in
`Native/OptChat/optchat-wasm`) for `wasm32-unknown-unknown` (`wasm-bindgen --target web`). Copied
verbatim (since 2026-10-16 newer than the copy in `experiments/chief-optmem/src/optchat-wasm/`). The Chief brain (`../brain-do.ts`) keeps its memory with it. Rebuild with
`experiments/chief-optmem/scripts/build-optchat-wasm.sh` on a build host (never the laptop), then
copy the four files here and in the experiment.

2026-10-16: rebuilt on cmux-rust-builder-1 (rbx lane hqec-optchat-wasm; rustc stable, wasm-bindgen-cli 0.2.129)
from this tree's `Native/OptChat/optchat-wasm`, which now exposes the core's checkpoint and lazy resume
(`checkpoint`, `OptChat.resume`, `makeLazy`, `isLazy`, `appendIn`, `completeIn`) for `../memory.ts`.

2026-10-19: rebuilt on cmux-rust-builder-1 (rbx lane hq1f-optchat-wasm; wasm-bindgen-cli 0.2.129) for the
compaction texts of the reference client: LEAF/MERGE verbatim (no "aim for about 400 bytes") and the
"small, mechanical job" paragraph. Only `optchat_wasm_bg.wasm` changed; the JS and type files are byte-identical.
The experiment's copy is older (its JS differs) and was not touched.

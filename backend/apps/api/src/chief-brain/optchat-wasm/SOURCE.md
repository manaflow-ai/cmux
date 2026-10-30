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

2026-10-28: rebuilt on cmux-rust-builder-1 (rustc 1.95.0, wasm-bindgen-cli 0.2.129, scratch
~/scratch/chief-d-wasm-db88970252b with `Native/OptChat/{optchat-core,chief-kernel,optchat-wasm}` and
`schemas/chief-profile`) from feat-cmux-next db88970252b: adds the chief-kernel exports `renderSystem`,
`toolSpecs`, `ledgerApply` and `OptChat.callPure` (cloud-chief-durable-DESIGN.md section 13). No
`wasm-opt` on that host: 629 KB (196 KB gzipped); the kernel lane measured 474 KB after `-Oz`.

2026-10-28 (later): rebuilt the same way from feat-cmux-next a71a7c2c3c8 for the kernel's cloud prompt
(`renderSystem` mode `cloud` with `offered`, f368f766bce), the ask and schedule ledgers (0361a630432,
cc183f53146) and the shorter Replies rule (aef76d5873a). 730 KB, no wasm-opt on that host.

2026-10-28 (later still): rebuilt from feat-cmux-next for dd5ff9e41a1 (the cloud base names only offered tools).

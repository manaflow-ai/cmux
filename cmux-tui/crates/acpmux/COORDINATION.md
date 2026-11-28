# acpmux coordination

- Work started: 2026-09-19 18:12:01 PDT (2026-09-20 01:12:01 UTC)
- Baseline before this work: `8ceec300b98633bfbe4cb748540842daf1f99538`
- Baseline subject: `TUI: the draft hero uses the chip labels for model, effort and policy`
- Baseline branch: `main` (tracking `origin/main`)
- Checkout moved from `/Users/lawrence/fun/human/acpmux` to `/Users/lawrence/fun/acpmux`.

## Skills, configurable shortcuts, and directory controls

This session owns `src/tui/keymap.rs`, `src/tui/skills.rs`, `src/tui/directory.rs`,
TUI config/picker/key routing, separate draft settings buttons, directory clicks and
composer `cd`, plus related docs/tests. Work builds on the baseline above and the
uncommitted UI changes from this session. Noticed concurrent transcript-cache edits
(`src/transcript.rs`, `src/tui/render/cache.rs` and integration fields); preserving
those edits and keeping construction/render integration compatible. Please retain
`make_app` in `src/tui/run.rs`, which is shared by the TUI and interaction tests.

Integration note: renderer/terminal edits are concurrent. My interaction tests now
call `render::draw` explicitly, since the shared import was removed. Last combined
build also reported `terminal.rs:96` calling private `writer_mut`; leaving terminal
implementation ownership with the renderer work while I finish UI routing tests.

UI implementation ready for release: configurable app bindings and sequential chords,
custom command/skill prefixes, local skill discovery and prompt expansion, independent
settings hit targets, and directory browsing via clicks or composer `cd` are implemented.
The combined suite passed 87 tests (one existing ignored performance test), including
render/input interaction and real framed-RPC assertions. The concurrent terminal build
error was fixed by renderer work; its changes remain intact. Release compilation and
atomic installation to ~/.local/bin/acpmux are in progress; the live daemon stays running.

Final release succeeded after the renderer source settled. The combined suite passed
88 tests (one existing performance test ignored); the final skill/directory/chord/native
command interaction test passed too. Source hashes were unchanged during the final build.
Installed via atomic rename to ~/.local/bin/acpmux; verified shell path, binary match,
version and CLI startup. A fresh `acpmux` TUI uses the new features immediately. The live
daemon remains running and serves its older embedded dashboard until restarted.

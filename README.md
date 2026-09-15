# Issue 12657 visual evidence

Synthetic Codex conversation: 40 numbered terminal-resize verification lines, no repository edits or tools requested.

- `before.png`: original main build `211b8bb35`, after narrowing/widening the window. The Codex text reaches/crops at the pane edge.
- `after.png`: runtime fix build `4b349d9f96` (runtime sources unchanged in `78996ee50d`), after quitting/relaunching cmux, restoring the workspace, resuming the same Codex conversation, and repeating divider and native window resizing. Text wraps within the pane and the input remains aligned.
- `after-resume-resize.mp4`: 22-second full-screen Cua Driver recording of the resumed Codex session through narrower/wider pane-divider drags. H.264, 2560x1440. This is a stream-copy trim of a verified 58-second full-screen recording; the raw recording remains in the task's local durable artifact directory.

Visual host: leased `cmuxs-mac-mini-2`, macOS 26.5. Codex CLI 0.0.0. Claude Code was installed but unauthenticated on this host, so authenticated Claude streaming after restore remains a dogfood check.

These captures demonstrate this observed resize/reflow path, not a guarantee against every previously reported intermittent compositing failure. The app PR is https://github.com/manaflow-ai/cmux/pull/12662.

# Issue 12657 visual evidence

Synthetic Codex conversation: 40 numbered terminal-resize verification lines; no repository edits or tools requested.

- `before.png`: original main build `211b8bb35`, after narrowing/widening the window. Codex text reaches/crops at the pane edge.
- `after.png`: final app build `5c6b07309cac74cef144dc0dacb5d06a0aaed722`, after restoring the two-pane workspace, resuming the same Codex conversation, four pane-divider drags, and narrowing/widening the native window. Output and input wrap within the pane.
- `after-divider.png`: the same final build after the repeated fullscreen divider drags.
- `after-resume-resize.mp4`: 44-second full-display Cua Driver recording of the final build's resumed Codex session through repeated narrower/wider divider drags. H.264, 2560x1440. A stream-copy edit removes idle intervals from the inspected 88-second raw full-display recording. The raw video, edit intervals, early/final frames, and ffprobe metadata remain in the local task artifact directory. No pixels were cropped or replaced.
- `validation.txt`: executed focused test names/results, regression-baseline assertions, and the app test invocation.

Visual host: leased `cmuxs-mac-mini-2`, macOS 26.5. Codex CLI 0.0.0. The workspace was restored and the conversation resumed through the tag-bound CLI during setup; visible resize gestures were driven through Cua Driver. The recording includes a nonblocking macOS Dock Tile Extension Added notification for another dev tag. It contains no unrelated desktop windows.

Claude Code 2.1.271 was installed but unauthenticated on this host. Authenticated Claude streaming after restore and the reporter's unknown macOS version remain unverified. These captures demonstrate this observed Codex resize/reflow path, not every reported intermittent garbling failure.

App PR: https://github.com/manaflow-ai/cmux/pull/12662

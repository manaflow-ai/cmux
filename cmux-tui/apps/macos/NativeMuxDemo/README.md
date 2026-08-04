# NativeMuxDemo

NativeMuxDemo is a standalone SwiftUI client for the cmux remote daemon. One
Iroh/Noise connection carries the public resource graph and multiple
`terminal-bytes-v1` streams. Every terminal has an independent local libghostty
emulator, Metal renderer, scrollback, selection, input encoder, and viewport.

Swift imports the `ghostty.h` C ABI from `GhosttyKit.xcframework` as the
`GhosttyKit` module. AppKit owns each persistent `NSView`, focus, and lifecycle;
libghostty owns terminal behavior and rendering. The upstream Ghostty Swift
views are useful implementation references, but they depend on Ghostty's app
delegate, configuration, menus, and controller graph, so this standalone client
calls `GhosttyKit` directly instead of treating those app sources as a package.
Rust owns Iroh, Noise, stream framing, and ordered renderer events. Its native
frontend build excludes `ghostty-vt`, so PTY output is parsed exactly once by
the Swift-hosted `GhosttyKit` surface.

The demo renders workspaces as vertical tabs, screens as spaces, viewport
columns as a horizontally scrolling niri layout, recursive splits, stacked
panes, and terminal/browser content as vertical pane tabs. Pane controls create
and focus each layout form through `cmux.protocol/1`.

From the cmuxterm-hq root:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/run-demo.sh
```

If the worktree has already been built, reuse its app and daemon binaries
without invoking an artifact producer:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/run-demo.sh --reuse-build
```

The standalone app bundle is at
`cmux-tui/target/native-mux-demo/NativeMuxDemo.app` inside the worktree.

The launcher builds the current worktree, starts an isolated ephemeral daemon,
seeds a representative layout, approves only its fresh enrollment invitation,
and removes the temporary state when the app closes.

# NativeMuxDemo

NativeMuxDemo is a standalone SwiftUI client for the cmux remote daemon. One
Iroh/Noise connection carries the public resource graph and multiple
`terminal-bytes-v1` streams. Every terminal has an independent local libghostty
parser and viewport.

The demo renders workspaces as vertical tabs, screens as spaces, viewport
columns as a horizontally scrolling niri layout, recursive splits, stacked
panes, and terminal/browser content as vertical pane tabs. Pane controls create
and focus each layout form through `cmux.protocol/1`.

From the cmuxterm-hq root:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/run-demo.sh
```

The launcher builds the current worktree, starts an isolated ephemeral daemon,
seeds a representative layout, approves only its fresh enrollment invitation,
and removes the temporary state when the app closes.

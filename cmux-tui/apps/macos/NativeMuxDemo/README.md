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
and seeds a representative layout. It then opens two independent Iroh clients
side by side: NativeMuxDemo uses Swift/AppKit and GhosttyKit on the left, while
Ghostty runs the ordinary `cmux-tui connect` frontend on the right. Each client
gets a separate one-use invitation and device identity. Type into either
frontend to see the same PTY output in both, scroll each viewport independently,
and close either client without terminating the shared PTY.

Pass `--swift-only` to omit the Ghostty client. Either client can detach while
the other keeps using the session. The launcher stops the isolated daemon and
closes every seeded terminal before removing its temporary state, so durable
terminal hosts and PTYs do not survive the demo.

Run the lifecycle regression against the reusable artifacts with:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/verify-demo-lifecycle.sh
```

The verifier launches the real Swift-only demo, closes the app, and fails if a
new terminal-host process survives. The launcher also checks that macOS has the
eight free PTYs needed by the seeded layout before it starts the daemon.

To prove the daemon and PTY can live on another Apple-silicon Mac while only
the native frontend runs locally:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/run-remote-demo.sh cmux-lawrence
```

The remote launcher verifies the host architecture, copies this worktree's
exact `cmux-tui` binary into a unique `/tmp` directory, starts an Iroh daemon,
creates one remote terminal, and transfers the single-use invitation only over
SSH. It gives an ad-hoc-signed temporary copy of the local app a unique bundle
identity, so an existing demo can stay open without LaunchServices mixing the
processes. The local app claims the invitation and the remote owner socket
approves that exact invitation. Closing the app closes the remote terminal and
removes both sides' temporary state. Closing its last window does the same,
even though macOS normally leaves a windowless app process alive. The launcher
does not replace the remote host's installed `cmux-tui`. It carries each remote
command's exit status in a framed stderr record because some SSH account
wrappers report success regardless of the command's real status.

Run three complete remote launch and cleanup cycles with:

```bash
worktrees/feat-cmux-tui-swift-frontend/cmux-tui/apps/macos/NativeMuxDemo/verify-remote-demo-lifecycle.sh cmux-lawrence 3
```

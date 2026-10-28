# cmux NEXT UI layer host

This Debug-only SwiftUI executable is a warm visual host for sidebar, tab bar,
pane and composer chrome. It reads a JSON projection from --snapshot PATH
(or CMUX_UI_LAYER_SNAPSHOT) and watches the containing directory for saves,
including atomic file replacement. With an explicit --attach SOCKET it mirrors
the current cmux NEXT topology from the local control socket. The attach path
subscribes to `events.stream` first, binds the stream boot and sequence to
`system.identify`, and coalesces notifications into fresh `snapshot.get`
reads. It stops on an identity change, event gap/reset or topology sequence
reset, and never falls back to a fixture.

Run from the repository root with:

    Prototypes/UiLayerHost/launch.sh --snapshot /tmp/cmux-ui-layer.json --watch

    Prototypes/UiLayerHost/launch.sh --attach "$HOME/.local/state/cmux/cmux-debug.sock" --watch

The checked-in Resources/cmux-ui-layer.example.json is a safe fixture. The
optional --watch flag uses the checked-in Swift DispatchSource vnode watcher to
restart the host after source saves and emits event timing without an external
watcher. The attach adapter only uses `system.identify`, `snapshot.get` and
`events.stream`: the current native snapshot exposes workspace/tab topology, so
chat transcript and sidebar document export remain future projection work.

The host imports `CmuxNextUiLayerPreview` from the real CmuxNext package. That
leaf product owns the preview surface and reuses production SwiftUI views from
`CmuxNextDesign` and `CmuxNextIcons`; it does not copy the app's views or link
`CmuxNextApp`. A save in one of those modules terminates and restarts this
small host, so the running cmux app is never touched. See
`docs/cmux-next/native-ui-host.md` for the fleet capture setup and timing
receipt format.

`cmux dev ui-host` is the one-command Debug/DEV entry point; when the CLI
wrapper is present it forwards to this launcher. Until that wrapper is landed,
run the launcher above on a developer or capture-slot Mac. The attach socket
must be a current-user local Debug/DEV cmux NEXT socket. This host is off by
default, is never run on Big Red, is excluded from release app targets, and
sends no user-data mutations.

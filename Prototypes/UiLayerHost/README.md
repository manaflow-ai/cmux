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
optional --watch flag uses event-based fswatch to restart the host after source
saves and emits elapsed timing when CMUX_UI_LAYER_TRACE=1; when fswatch is
unavailable it refuses clearly instead of polling. The attach adapter only
uses `system.identify`, `snapshot.get` and `events.stream`: the current native
snapshot exposes workspace/tab topology, so chat transcript and sidebar
document export remain future projection work. The prototype deliberately
uses a lightweight chrome shell: linking CmuxNext here would pull the app's
composition root and mutation-capable models into a standalone host.

`cmux dev ui-host` is the one-command Debug/DEV entry point; when the CLI
wrapper is present it forwards to this launcher. Until that wrapper is landed,
run the launcher above on the developer's own Mac. The attach socket must be a
current-user local Debug/DEV cmux NEXT socket. This host is off by default, is
never run on Big Red, and sends no user-data mutations.

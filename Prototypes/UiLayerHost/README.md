# cmux NEXT UI layer host

This Debug-only SwiftUI executable is a warm visual host for sidebar, tab bar,
pane and composer chrome. It reads a JSON projection from --snapshot PATH
(or CMUX_UI_LAYER_SNAPSHOT) and watches the containing directory for saves,
including atomic file replacement. It has no daemon socket, action registry,
or mutating client, so a malformed or stale projection cannot change a user's
cmux state.

Run from the repository root with:

    Prototypes/UiLayerHost/launch.sh --snapshot /tmp/cmux-ui-layer.json --watch

On a developer Mac with a Debug or DEV cmux build, the same launcher is
available as one command:

    cmux dev ui-host --snapshot /tmp/cmux-ui-layer.json --watch

This route is explicit and off by default. It only runs from a cmux checkout
(or an absolute path in `CMUX_UI_LAYER_REPO`), refuses release builds and
non-macOS hosts, and does not discover a daemon socket. Pass a projection with
`--snapshot`; the launcher never sends commands to cmuxd or mutates its state.

The checked-in Resources/cmux-ui-layer.example.json is a safe fixture. The optional --watch flag uses event-based fswatch to restart the host after source saves and emits elapsed timing when CMUX_UI_LAYER_TRACE=1; when fswatch is unavailable it refuses clearly instead of polling. A
future exporter can map a read-only workspace.list response into this small
schema without making the host depend on the full app target. The prototype
deliberately uses a lightweight chrome shell: linking CmuxNext here would pull
the app's composition root and mutation-capable models into a standalone host.
The follow-up seam is an injected, read-only adapter that maps
DaemonConnection.snapshot() into the same DTOs before reusing production views.

cmux ui-layer is intentionally not a production CLI alias in this v0. Use the
launcher above until that adapter and target wiring have a fleet build and
capture receipt.

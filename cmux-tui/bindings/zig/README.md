# cmux resource SDK for Zig

The SDK targets Zig 0.15.2 and uses only the standard library. The default API
uses typed opaque resource IDs, explicit handles, caller allocators, explicit
`deinit`, cryptographically random mutation keys, and typed streams.

```zig
const std = @import("std");
const cmux = @import("cmux_tui");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var client = try cmux.Client.connect(allocator, .{
        .session = "main",
        .timeout_ms = 10_000,
    });
    defer client.deinit();

    const workspace = client
        .machine(.current)
        .session(.{ .name = "main" })
        .workspace(.{ .name = "sdk" });
    const command = try cmux.RunCommand.argv(&.{
        "cargo",
        "test",
        "--workspace",
    });
    var started = try workspace.run(
        .{ .command = command, .cwd = "/checkout" },
        cmux.MutationOptions.random().expecting(42),
    );
    defer started.deinit();
}
```

`RunCommand.argv` preserves each argument. `RunCommand.shell` sends a script
for the server platform default shell. `shellWithExecutable` encodes exact
`[executable, "-lc", script]` arguments.

Each mutation sends one caller-visible idempotency key and never retries
implicitly. Typed mutation results contain their concrete value, generation,
revision, and replayed fields. Results never echo the request’s idempotency
key. Creation results expose typed workspace, terminal, or browser paths.

If a mutation loses its response to any transport failure after its complete
JSON payload is written, the call returns
`error.MutationTransportUncertain`. Inspect
`client.lastMutationTransportUncertain()` or transfer ownership with
`client.takeMutationTransportUncertain()`. The typed value contains the
operation, categorized transport cause, exact generated or supplied
idempotency key, and recovery instruction. The SDK never retries automatically
because the server may have committed the mutation.

The socket binds a client to its current machine and session. `Client.session`
accepts ID, current, and name selectors. `Client.workspace(id)` includes
current machine and session selectors. Nested handles retain every ancestor,
so current and name targets serialize a complete machine through tab route.
Constructing, copying, and discarding a handle performs no I/O. Selector name
slices are borrowed for the handle lifetime.

Each public facade declares only capabilities valid for that resource.
`Terminal.navigate`, `Browser.readScreen`, `Machine.close`, and viewer
controls on non-attachment streams fail at compile time and stay out of
autocomplete. Notifications and agents are list/create/report resources, so
the SDK exposes their snapshots and session methods without unusable
individual handles.

Machine, session, and workspace discovery returns owned typed snapshots:

```zig
var machines = try client.listMachines();
defer machines.deinit();
for (machines.items) |machine_snapshot| {
    var sessions = try client
        .machine(machine_snapshot.id)
        .listSessions();
    defer sessions.deinit();
    for (sessions.items) |session_snapshot| {
        var workspaces = try client
            .machine(machine_snapshot.id)
            .session(session_snapshot.id)
            .listWorkspaces();
        defer workspaces.deinit();
        for (workspaces.items) |workspace_snapshot| {
            try persistWorkspace(
                workspace_snapshot.id,
                workspace_snapshot.name,
            );
        }
    }
}
```

Lists preserve every item when names are duplicated. Their snapshot slices
remain valid until the list is deinitialized, including after the client is
closed. `refresh` returns the corresponding owned concrete snapshot for
machine, session, and workspace handles.

Terminal reads decode catalog results without JSON traversal:

```zig
const terminal = client.terminal(terminal_id);

var screen = try terminal.readScreen();
defer screen.deinit();
try stdout.writeAll(screen.value.text);

var history = try terminal.readHistory(.{ .limit = 200, .styled = true });
defer history.deinit();
for (history.value.rows) |row| {
    for (row.runs) |run| try stdout.writeAll(run.text);
}

var state = try terminal.readState();
defer state.deinit();
try replayVt(state.value.state);
```

`readState` retains `state_base64` and exposes decoded replay bytes as
`state`. Screen results retain the catalog-defined `extra` map. History,
state, wait, copy, process, viewer resize/release, renderer grants, and empty
history-clear mutation receipts all have owned typed results.

Terminal snapshots expose `lifecycle` and an optional durable `exit` record.
The exit record preserves exited-at time, revision, and an `exited`,
`signaled`, or unknown outcome. `waitExit` returns either a pending lifecycle
or the same durable exit record, so callers do not infer process completion
from attachment closure.

Client metadata and cell-pixel controls, browser navigation, notifications,
agents, pairing requests, frontend projections, sidebar views, layouts, and
every other catalog operation return concrete typed values. Names preserve
exact bytes. Workspace `clearName` sets the empty string. Screen, pane, and
tab `clearName` send JSON null.
`ClientMetadataUpdate` distinguishes unchanged, set (including empty), and
clear states.

Destructive layout undo uses the capability returned by
`confirmation.required`:

```zig
const details = switch (client.lastResourceError().?.details) {
    .confirmation_required => |value| value,
    else => return error.UnexpectedResourceError,
};
var undone = try screen.undoLayout(
    .{
        .confirm_close = true,
        .confirmation_token = details.confirmation_token,
    },
    cmux.MutationOptions.random().expecting(details.revision),
);
defer undone.deinit();
```

`SessionEvent` is a tagged `snapshot`, `delta`, or `unknown` union. Delta
changes are tagged `upsert`, `delete`, or `unknown` values. Unknown variants
retain their discriminator and complete raw object. A malformed recognized
variant is a decode error. Terminal, browser, and sidebar attachment streams
use the same unknown-discriminator rule. Stream queues are bounded to 256
items and 16 MiB. Overflow closes only that stream connection and reports a
gap with `sdk.buffer_overflow` recovery. Cancellation waits for both the
response and terminal stream end, including end-before-response ordering.
Structured end errors retain code, message, typed redacted details, and
retryability.

Attachments use dedicated connections. Resize and release methods live on
`TerminalAttachmentStream` and `BrowserAttachmentStream`, so connection-local
viewer state cannot accidentally be changed through the control client.
Session event streams accept a resume cursor. Attachment options configure
initial read-only state and terminal or browser dimensions.

Every browser `frame` item requires a `pointer_frame_seq` field on the wire.
The SDK exposes it as `?u64`: `null` keeps the bitmap renderable but disables
pointer input. After presenting a frame, pass its exact non-null token to every
mouse or wheel input. The SDK serializes the required token as an unsigned
decimal string, including values above JSON's safe integer range.

```zig
const pointer_frame_seq = frame.pointer_frame_seq orelse
    return error.PointerInputUnavailable;
var sent = try browser.sendBrowserMouse(.{
    .kind = .move,
    .x_px = 240,
    .y_px = 120,
    .pointer_frame_seq = pointer_frame_seq,
}, cmux.MutationOptions.random());
defer sent.deinit();
```

Catalog errors use the `ResourceErrorDetails` tagged union. For example,
`selector_ambiguous.candidates` contains typed `ErrorResourceId` values and
`mutation_indeterminate` exposes its operation, idempotency key, and recovery
instruction without JSON traversal. A future error code uses `unknown`; a
known code with an incompatible payload uses `malformed`. Both fallbacks own
and retain their redacted raw detail value.

Live renderer grants retain their response storage. Offline tools can build
the same validated, owned value without transport:

```zig
const grant = try cmux.RendererGrant.init(allocator, .{
    .endpoint = "/tmp/cmux-renderer.sock",
    .terminal_id = terminal_id,
    .token = .{ .bytes = token_from_secure_storage },
    .rights = &.{ "read", "input" },
    .ttl_ms = 5_000,
});
defer grant.deinit();

try renderer.connect(grant.endpoint(), grant.token().reveal());
```

Grant data is available only through accessors. Formatting a grant or token
prints `[REDACTED]`.

Generated protocol-v12 compatibility APIs remain available only under the
explicit raw namespace:

```zig
const protocol = cmux.raw.protocol;
const RawClient = cmux.raw.Client;
```

`raw.Options.timeout_ms` bounds Unix-socket establishment and each later raw
transport read or write. `null` disables transport deadlines.

Every returned owned snapshot, list, result, mutation result, stream item,
stream, and renderer grant documents ownership through a `deinit` method.
Request slices are borrowed only until the call returns.

Protocol `decimal` values are accepted only as canonical unsigned base-10
JSON strings, including the full `u64` range. Numeric JSON, signs, and leading
zeroes are rejected. Ordinary integer fields remain JSON numbers.

Build and test:

```sh
zig build test
zig build
```

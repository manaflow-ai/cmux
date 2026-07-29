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

    const workspace_id = try cmux.WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    const command = try cmux.RunCommand.argv(&.{
        "cargo",
        "test",
        "--workspace",
    });
    var started = try client.workspace(workspace_id).run(
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
implicitly. `MutationResult` contains the flat canonical value, generation,
revision, and replayed fields. Results never echo the request’s idempotency
key. `createdPath` parses a typed workspace, terminal, or browser path from a
creation result’s value.

The socket binds a client to its current machine and session. The client adds
those selectors when callers supply only an opaque target ID. Handles contain
a typed ID and client pointer, and perform no I/O when copied or discarded.

Names preserve exact bytes. Workspace and machine `clearName` set the empty
string. Screen, pane, and tab `clearName` send JSON null.
`ClientMetadataUpdate` distinguishes unchanged, set (including empty), and
clear states.

Typed streams cover session events, terminal attachment items, browser
attachment items, sidebar view items, and provider notices. Unknown payload
fields remain available through each item’s `extra` value. Cancellation waits
for both the response and terminal stream end, including end-before-response
ordering. Structured end errors retain code, message, redacted details, and
retryability.
Provider notices are acknowledged explicitly with
`try provider_scope.notice(id).acknowledge(sequence)` after the consumer
paints the notice; iteration never acknowledges delivery.

Renderer grants expose endpoint, terminal ID, rights, TTL, and a
`SensitiveString` token. Formatting a grant, token, or provider credential
prints `[REDACTED]`.

Generated protocol-v10 compatibility APIs remain available only under the
explicit raw namespace:

```zig
const protocol = cmux.raw.protocol;
const RawClient = cmux.raw.Client;
```

Every returned `OwnedResult`, `MutationResult`, stream item, stream, and
renderer grant documents ownership through a `deinit` method. Request slices
are borrowed only until the call returns.

Build and test:

```sh
zig build test
zig build
```

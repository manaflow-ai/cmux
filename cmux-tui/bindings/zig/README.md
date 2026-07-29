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
implicitly. `MutationResult` contains the flat canonical value, generation,
revision, and replayed fields. Results never echo the request’s idempotency
key. `createdPath` parses a typed workspace, terminal, or browser path from a
creation result’s value.

The socket binds a client to its current machine and session. `Client.session`
accepts ID, current, and name selectors. `Client.workspace(id)` includes
current machine and session selectors. Nested handles retain every ancestor,
so current and name targets serialize a complete machine through tab route.
Constructing, copying, and discarding a handle performs no I/O. Selector name
slices are borrowed for the handle lifetime.

Names preserve exact bytes. Workspace and machine `clearName` set the empty
string. Screen, pane, and tab `clearName` send JSON null.
`ClientMetadataUpdate` distinguishes unchanged, set (including empty), and
clear states.

`SessionEvent` is a tagged `snapshot`, `delta`, or `unknown` union. Delta
changes are tagged `upsert`, `delete`, or `unknown` values. Unknown variants
retain their discriminator and complete raw object. A malformed recognized
variant is a decode error. Other typed streams retain unknown payload fields
through each item’s `extra` value. Cancellation waits for both the response
and terminal stream end, including end-before-response ordering. Structured
end errors retain code, message, redacted details, and retryability.
Provider notices are acknowledged explicitly with
`try provider_scope.notice(id).acknowledge(sequence)` after the consumer
paints the notice; iteration never acknowledges delivery.

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

Grant data is available only through accessors. Formatting a grant, token, or
provider credential prints `[REDACTED]`.

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

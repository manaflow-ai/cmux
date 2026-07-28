# cmux TUI SDK for Zig

Version 0.4.0 targets mux protocol 10 and Zig 0.15.2. It uses only Zig's standard library.

The generated layer contains all 83 commands, 44 event payloads, named wire models, exact protocol metadata, and typed request/result methods. Handwritten code owns Unix socket discovery, bounded JSON-lines framing, lossless `uint64` decoding, timeouts, pre-ack event buffering, stream termination, and cancellation.

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

    var identity = try cmux.protocol.identify(&client, .{});
    defer identity.deinit();
    std.debug.print("{s}\n", .{identity.value.version});
}
```

Direct `Client` connections use `AuthorityPolicy.local` by default. This
permits control, frontend, and local-admin commands, while all generated
provider-authority methods return `error.ProviderAuthorityDenied` before
request serialization or a socket write. Prefer `ProviderClient`, which
explicitly enables provider authority while owning and zeroing the authority
secret. Low-level integrations can opt in directly:

```zig
var client = try cmux.Client.connect(allocator, .{
    .authority_policy = .provider_authority,
});
defer client.deinit();
```

Every generated call carries its authority, minimum protocol, capability, and
optional-field requirements into `Client`. The first typed call lazily sends
`identify` and caches the server protocol and capabilities. Unsupported
commands return `error.UnsupportedProtocol` or `error.MissingCapability`
before the command write; present gated fields return
`error.UnsupportedFieldProtocol` or `error.MissingFieldCapability`. Calling
generated `identify` populates the same cache, and `client.negotiate()` can
perform the handshake explicitly.

Forward-compatible extensions can use `callUnchecked` or
`openStreamUnchecked`, supplying both the new wire name and its authority.
These skip protocol and capability checks but retain the authority policy.

Capability checks are available without reimplementing a slice scan:

```zig
const server_capabilities = identity.value.capabilities orelse &.{};
try cmux.requireCapability(
    server_capabilities,
    "workspace-registry-v1",
);
if (cmux.hasCapability(
    server_capabilities,
    "provider-managed-workspace-authority-v2",
)) {
    // Provider-owned workspace lifecycle APIs are available.
}
```

Decoded results own an arena. Call `deinit` on every result and event. Request
strings and slices are borrowed only until the call returns. Generated
optional non-null properties use `?T`: Zig `null` omits the property when
encoding, while an explicit JSON `null` is rejected when decoding. Schema
defaults do not erase this wire-presence distinction, so callers can apply a
fallback with `orelse`. `Field(T)` preserves absent, explicit null, and value
states for optional nullable properties. `Nullable(T)` represents required
nullable properties and rejects omission. Generated enums reject unknown wire
spellings, `Map(T)` keeps JSON object values typed, and `encodeBase64Alloc` or
`decodeBase64Alloc` handles byte payloads.

Remote command rejection still returns `error.RemoteError`. The borrowed
`lastRemoteError()` message is cleared before the next call. Prefer
`takeRemoteError()` when the message must outlive the call:

```zig
var result = cmux.protocol.identify(&client, .{}) catch |err| {
    if (err == error.RemoteError) {
        var remote = client.takeRemoteError().?;
        defer remote.deinit();
        std.debug.print("server rejected identify: {s}\n", .{remote.message});
    }
    return err;
};
defer result.deinit();
```

## Provider-owned workspaces

`ProviderClient` owns its base client, explicitly enables provider authority,
securely zeroes its copied authority, checks protocol 9 plus the
workspace-registry and provider-authority capabilities, marks provider
ownership, and retains an allocator-owned workspace snapshot.

```zig
var provider_client = try cmux.ProviderClient.connect(allocator, .{
    .authority = provider_authority,
    .client = .{ .socket_path = "/path/to/cmux-tui.sock" },
});
defer provider_client.deinit();

const snapshot = try provider_client.currentSnapshot();
const created = try provider_client.createWorkspace(.{
    .expected_revision = snapshot.workspace_revision,
    .name = "worker",
    .key = "22222222-2222-4222-8222-222222222222",
    .mutation_id = "create-worker-1",
});
const renamed = try provider_client.renameWorkspace(.{
    .expected_revision = created.workspace_revision,
    .workspace = created.workspace,
    .key = "22222222-2222-4222-8222-222222222222",
    .name = "production",
});
_ = try provider_client.closeWorkspace(.{
    .expected_revision = renamed.workspace_revision,
    .workspace = renamed.workspace,
    .key = "22222222-2222-4222-8222-222222222222",
});
```

Use `ProviderClient.open` followed by `initialize` when an authority handshake
failure must be retrieved with `takeRemoteError`. `wrapOwned` and
`fromOwnedClient` consume an existing connected `Client`; the caller must not
use or deinitialize the moved value.

`createWorkspace` sends generation and revision compare-and-swap guards.
Provider rename and close currently lack wire revision guards. Their
`expected_revision` checks are local, and the returned revision must be
contiguous, but another controller can still commit between the local check
and the request. Call `snapshot` after a conflict or `error.RevisionGap`.
Snapshots borrow copied workspace data until the next snapshot, mutation, or
provider-client deinitialization. Externally synchronize a `ProviderClient`
when sharing it across threads; a concurrent mutation can invalidate a
borrowed snapshot.

Each subscription or surface attachment should use a dedicated `Client`.
Clients opened with `Client.connect` retain the resolved socket path, so
`openStreamClient` opens an independent connection with the same timeout,
limits, and authority policy:

```zig
var stream_client = try client.openStreamClient();
defer stream_client.deinit();
var events = try cmux.protocol.subscribe(&stream_client, .{});
defer events.deinit();
```

Events that arrive before the stream acknowledgement are buffered in order.
`overflow` is returned once and then ends the stream. Unknown event names
become `.unknown`, preserving their raw JSON for forward compatibility.
`cmux.eventWireName(event.value)` returns the exact generated wire name for
known events and the preserved name for unknown events.
`Stream.close()` or `Client.close()` shuts down the transport and unblocks a
pending read.

Socket discovery checks an explicit `socket_path`, `CMUX_TUI_SOCKET`, `CMUX_MUX_SOCKET`, then the per-user runtime directory. Limits are configurable through `Options.limits`:

```zig
var client = try cmux.Client.connect(allocator, .{
    .socket_path = "/tmp/cmux-tui-501/main.sock",
    .limits = .{
        .max_frame_bytes = 16 * 1024 * 1024,
        .max_depth = 64,
        .max_pre_ack_events = 4096,
    },
});
```

Run:

```sh
zig build test
zig build
```

Regenerate the checked-in wire layer from the repository root:

```sh
python3 cmux-tui/bindings/codegen/generate.py --write --language zig
python3 cmux-tui/bindings/codegen/generate.py --check --language zig
```

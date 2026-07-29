const std = @import("std");
const cmux = @import("cmux_tui");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var client = try cmux.Client.connect(allocator, .{});
    defer client.deinit();

    var machines = try client.machines();
    defer machines.deinit();
    const encoded = try cmux.raw.wire.stringifyAlloc(
        allocator,
        machines.value,
    );
    defer allocator.free(encoded);
    std.debug.print("machine inventory: {s}\n", .{encoded});
}

test "package consumer imports handwritten root and generated raw module" {
    const workspace = try cmux.WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    var selector = cmux.Selector(cmux.WorkspaceId){ .name = "current" };
    const encoded = try selector.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("name:current", encoded);
    try std.testing.expectEqualStrings(
        "ws_0123456789abcdef0123456789abcdef",
        workspace.slice(),
    );
    try std.testing.expectEqual(
        @as(usize, 87),
        cmux.raw.protocol.command_count,
    );
    try std.testing.expectEqual(
        @as(usize, 44),
        cmux.raw.protocol.event_count,
    );

    // Handle construction stores selectors and routes without touching the
    // client, so an external consumer can compose a route before connecting.
    var offline_client: cmux.Client = undefined;
    const terminal = offline_client
        .machine(.current)
        .session(.{ .name = "main" })
        .workspace(.{ .name = "sdk" })
        .screen(.current)
        .pane(.current)
        .tab(.current)
        .terminal(.{ .name = "shell" });
    try std.testing.expect(terminal.id() == null);

    const terminal_id = try cmux.TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const grant = try cmux.RendererGrant.init(std.testing.allocator, .{
        .endpoint = "/tmp/cmux-renderer.sock",
        .terminal_id = terminal_id,
        .token = .{ .bytes = "secret" },
        .rights = &.{ "read", "input" },
        .ttl_ms = 5_000,
    });
    defer grant.deinit();
    try std.testing.expectEqualStrings(
        "/tmp/cmux-renderer.sock",
        grant.endpoint(),
    );
}

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
    std.debug.print("machine inventory: {f}\n", .{machines.value});
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
        @as(usize, 83),
        cmux.raw.protocol.command_count,
    );
    try std.testing.expectEqual(
        @as(usize, 44),
        cmux.raw.protocol.event_count,
    );
}

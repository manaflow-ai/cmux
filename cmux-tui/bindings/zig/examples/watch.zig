const std = @import("std");
const cmux = @import("cmux_tui");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var client = try cmux.Client.connect(allocator, .{});
    defer client.deinit();

    var identity = try cmux.protocol.identify(&client, .{});
    defer identity.deinit();
    std.debug.print(
        "cmux {s}, session {s}, protocol {d}\n",
        .{
            identity.value.version,
            identity.value.session,
            identity.value.protocol,
        },
    );

    // Streams use their own connection so closing one cancels only that reader.
    var stream_client = try cmux.Client.connect(allocator, .{});
    defer stream_client.deinit();
    var stream = try cmux.protocol.subscribe(
        &stream_client,
        .{ .tree_events = .{ .value = .deltas } },
    );
    defer stream.deinit();

    while (try cmux.protocol.nextEvent(&stream, allocator)) |decoded_value| {
        var event = decoded_value;
        defer event.deinit();
        switch (event.value) {
            .workspace_added => |added| std.debug.print(
                "workspace added: {d}\n",
                .{added.workspace},
            ),
            .workspace_closed => |closed| std.debug.print(
                "workspace closed: {d}\n",
                .{closed.workspace},
            ),
            .overflow => break,
            .unknown => |unknown| std.debug.print(
                "new event from a newer server: {s}\n",
                .{unknown.name},
            ),
            else => {},
        }
    }
}

test "package consumer sees generated protocol inventory" {
    try std.testing.expectEqual(@as(usize, 83), cmux.protocol.command_count);
    try std.testing.expectEqual(@as(usize, 44), cmux.protocol.event_count);
    try std.testing.expectEqual(@as(u16, 10), cmux.protocol.mux_protocol);
}

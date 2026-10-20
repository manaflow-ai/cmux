const std = @import("std");
const cmux = @import("../cmux.zig");
const raw = @import("../raw.zig");

const owner = "machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const record = "{\"id\":\"" ++ owner ++ "\",\"name\":\"owner\",\"origin\":\"local\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false}";
const rich_record = record[0 .. record.len - 1] ++ ",\"platform\":{\"os\":\"linux\"}}";
const Peer = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    processed: usize = 0,

    pub fn writeAll(self: *@This(), bytes: []const u8, _: ?u32) !void {
        try self.output.appendSlice(self.allocator, bytes);
        while (std.mem.indexOfScalarPos(u8, self.output.items, self.processed, '\n')) |end| {
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, self.output.items[self.processed..end], .{});
            defer parsed.deinit();
            const frame = parsed.value.object;
            const operation = frame.get("operation").?.string;
            const id = frame.get("id").?.string;
            const params = frame.get("params").?.object;
            const extended = if (params.get("catalog")) |flag| flag == .bool and flag.bool else false;
            const listing = std.mem.eql(u8, operation, "machine.list");
            const value = if (listing and extended)
                "[" ++ rich_record ++ "]"
            else if (listing)
                "[" ++ record ++ "]"
            else if (extended)
                rich_record
            else
                record;
            const reply = try std.fmt.allocPrint(self.allocator, "{{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\",\"id\":\"{s}\",\"ok\":true,\"result\":{s}}}\n", .{ id, value });
            defer self.allocator.free(reply);
            try self.input.appendSlice(self.allocator, reply);
            self.processed = end + 1;
        }
    }

    pub fn read(self: *@This(), buffer: []u8, _: ?u32) !usize {
        if (self.cursor == self.input.items.len) return error.Timeout;
        const count = @min(buffer.len, self.input.items.len - self.cursor);
        @memcpy(buffer[0..count], self.input.items[self.cursor..][0..count]);
        self.cursor += count;
        return count;
    }

    pub fn close(_: *@This()) void {}

    pub fn deinit(self: *@This()) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

test "cmux_next_machine_sdk_catalog_opt_in preserves defaults and captured owners" {
    const allocator = std.testing.allocator;
    const peer = try allocator.create(Peer);
    peer.* = .{ .allocator = allocator };
    var client = cmux.Client.init(allocator, raw.transport.Connection.from(peer), .{});
    defer client.deinit();
    {
        var result = try client.listMachines();
        defer result.deinit();
    }
    {
        var result = try client.listMachinesWith(.{ .catalog = true });
        defer result.deinit();
    }
    {
        var result = try client.listMachinesWith(.{});
        defer result.deinit();
    }
    const machine = client.machine(try cmux.MachineId.parse(owner));
    {
        var result = try machine.refresh();
        defer result.deinit();
    }
    var rich = try machine.refreshWith(.{ .catalog = true });
    defer rich.deinit();
    {
        var result = try machine.refreshWith(.{});
        defer result.deinit();
    }
    var lines = std.mem.splitScalar(u8, peer.output.items, '\n');
    var index: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const frame = parsed.value.object;
        const params = frame.get("params").?.object;
        const extended = index == 1 or index == 4;
        if (extended) {
            const flag = params.get("catalog") orelse return error.MissingCatalogOptIn;
            try std.testing.expectEqual(true, flag.bool);
        } else try std.testing.expect(params.get("catalog") == null);
        if (index >= 3) try std.testing.expectEqualStrings(owner, params.get("machine").?.string);
        try std.testing.expect(params.get("session") == null);
        try std.testing.expect(frame.get("idempotency_key") == null);
        index += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), index);
    const platform = rich.value.platform orelse return error.MissingOwnerPlatform;
    try std.testing.expectEqualStrings("linux", platform.os orelse return error.MissingOwnerOS);
}

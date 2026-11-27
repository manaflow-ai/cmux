const std = @import("std");
const cmux = @import("../cmux.zig");
const raw = @import("../raw.zig");

const screen = "screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const workspace = "ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const chain = "split_dddddddddddddddddddddddddddddddd";
const good_rows = "[{\"row_id\":\"split_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"height\":600},{\"row_id\":\"" ++ chain ++ "\",\"height\":400}]";

/// A rows-v1 layout document: column 0 has `rows`, column 1 has one row.
fn document(comptime rows: []const u8) []const u8 {
    return "{\"version\":1,\"screen_id\":\"" ++ screen ++ "\",\"active_pane_id\":\"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"zoomed_pane_id\":null,\"root\":{\"kind\":\"viewport\",\"base_width\":0.5,\"columns\":[" ++
        "{\"column_id\":\"split_cccccccccccccccccccccccccccccccc\",\"width\":0.5,\"root\":{\"kind\":\"split\",\"split_id\":\"" ++ chain ++
        "\",\"direction\":\"vertical\",\"ratio\":0.6,\"first\":{\"kind\":\"leaf\",\"pane_id\":\"pane_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"tab_ids\":[]}," ++
        "\"second\":{\"kind\":\"leaf\",\"pane_id\":\"pane_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"tab_ids\":[]}},\"rows\":" ++ rows ++ "}," ++
        "{\"column_id\":\"split_ffffffffffffffffffffffffffffffff\",\"width\":0.5,\"root\":{\"kind\":\"leaf\",\"pane_id\":\"pane_cccccccccccccccccccccccccccccccc\",\"tab_ids\":[]}}]}}";
}

/// Answers screen.layout.export with `layout` and refuses every other
/// request, keeping what was sent.
const Peer = struct {
    allocator: std.mem.Allocator,
    layout: []const u8,
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
            const id = frame.get("id").?.string;
            const reply = if (std.mem.eql(u8, frame.get("operation").?.string, "screen.layout.export"))
                try std.fmt.allocPrint(self.allocator, "{{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\",\"id\":\"{s}\",\"ok\":true,\"result\":{s}}}\n", .{ id, self.layout })
            else
                try std.fmt.allocPrint(self.allocator, "{{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\",\"id\":\"{s}\",\"ok\":false,\"error\":{{\"code\":\"operation.failed\",\"message\":\"recorded\",\"retryable\":false,\"details\":{{}}}}}}\n", .{id});
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

fn client(allocator: std.mem.Allocator, layout: []const u8) !struct { client: cmux.Client, peer: *Peer } {
    const peer = try allocator.create(Peer);
    peer.* = .{ .allocator = allocator, .layout = layout };
    return .{ .client = cmux.Client.init(allocator, raw.transport.Connection.from(peer), .{}), .peer = peer };
}

test "layout documents decode a column's rows and send them back" {
    const allocator = std.testing.allocator;
    var connected = try client(allocator, document(good_rows));
    defer connected.client.deinit();
    var layout = try connected.client.screen(try cmux.ScreenId.parse(screen)).exportLayout();
    defer layout.deinit();
    const viewport = switch (layout.value.root.*) {
        .viewport => |viewport| viewport,
        else => return error.ExpectedViewport,
    };
    const rows = viewport.columns[0].rows orelse return error.MissingRows;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(u16, 600), rows[0].height);
    try std.testing.expectEqual(@as(u16, 400), rows[1].height);
    try std.testing.expectEqualStrings(chain, (rows[1].row_id orelse return error.MissingRowId).slice());
    try std.testing.expect(viewport.columns[1].rows == null);

    if (connected.client.workspace(try cmux.WorkspaceId.parse(workspace)).applyLayout(layout.value, try cmux.MutationOptions.withKey("layout-rows-test"))) |result| {
        var applied = result;
        applied.deinit();
        return error.ExpectedRefusal;
    } else |_| {}
    var lines = std.mem.splitScalar(u8, connected.peer.output.items, '\n');
    var seen = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const frame = parsed.value.object;
        if (!std.mem.eql(u8, frame.get("operation").?.string, "workspace.layout.apply")) continue;
        const columns = frame.get("params").?.object.get("layout").?.object.get("root").?.object.get("columns").?.array.items;
        const sent = columns[0].object.get("rows").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), sent.len);
        try std.testing.expectEqualStrings(chain, sent[1].object.get("row_id").?.string);
        try std.testing.expectEqual(@as(i64, 600), sent[0].object.get("height").?.integer);
        try std.testing.expect(columns[1].object.get("rows") == null);
        seen = true;
    }
    try std.testing.expect(seen);
}

test "layout rows keep row 1 without an id and refuse bad rows" {
    const allocator = std.testing.allocator;
    {
        var connected = try client(allocator, document("[{\"height\":500},{\"row_id\":\"" ++ chain ++ "\",\"height\":400}]"));
        defer connected.client.deinit();
        var layout = try connected.client.screen(try cmux.ScreenId.parse(screen)).exportLayout();
        defer layout.deinit();
        const rows = layout.value.root.viewport.columns[0].rows.?;
        try std.testing.expect(rows[0].row_id == null);
        try std.testing.expectEqual(@as(u16, 500), rows[0].height);
    }
    inline for (.{
        "[{\"row_id\":\"" ++ chain ++ "\",\"height\":600,\"width\":1}]",
        "[{\"row_id\":\"" ++ chain ++ "\",\"height\":50}]",
        "[{\"row_id\":\"" ++ chain ++ "\",\"height\":1001}]",
        "[{\"row_id\":\"" ++ chain ++ "\"}]",
        "\"rows\"",
    }) |bad| {
        var connected = try client(allocator, document(bad));
        defer connected.client.deinit();
        if (connected.client.screen(try cmux.ScreenId.parse(screen)).exportLayout()) |decoded| {
            var layout = decoded;
            layout.deinit();
            return error.ExpectedRefusal;
        } else |_| {}
    }
}

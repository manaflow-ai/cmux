const std = @import("std");
const client_module = @import("client.zig");
const protocol = @import("generated/protocol.zig");

const RecordingConnection = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize = 0,
    output: std.ArrayList(u8) = .empty,
    closed: bool = false,

    fn create(input: []const u8) !*RecordingConnection {
        const state = try std.testing.allocator.create(RecordingConnection);
        state.* = .{
            .allocator = std.testing.allocator,
            .input = input,
        };
        return state;
    }

    pub fn read(
        self: *RecordingConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = timeout_ms;
        if (self.closed) return error.ConnectionClosed;
        if (self.cursor == self.input.len) return 0;
        const count = @min(buffer.len, self.input.len - self.cursor);
        @memcpy(buffer[0..count], self.input[self.cursor..][0..count]);
        self.cursor += count;
        return count;
    }

    pub fn writeAll(
        self: *RecordingConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = timeout_ms;
        if (self.closed) return error.ConnectionClosed;
        try self.output.appendSlice(self.allocator, bytes);
    }

    pub fn close(self: *RecordingConnection) void {
        self.closed = true;
    }

    pub fn deinit(self: *RecordingConnection) void {
        const allocator = self.allocator;
        self.output.deinit(allocator);
        allocator.destroy(self);
    }
};

test "default client denies every generated provider entrypoint before write" {
    const state = try RecordingConnection.create("");
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.ProviderAuthorityDenied,
        protocol.markWorkspacesProviderManaged(&client, .{
            .authority = "secret",
        }),
    );
    try std.testing.expectError(
        error.ProviderAuthorityDenied,
        protocol.renameProviderManagedWorkspace(&client, .{
            .authority = "secret",
            .workspace = 1,
            .key = "11111111-1111-4111-8111-111111111111",
            .name = "renamed",
        }),
    );
    try std.testing.expectError(
        error.ProviderAuthorityDenied,
        protocol.closeProviderManagedWorkspace(&client, .{
            .authority = "secret",
            .workspace = 1,
            .key = "11111111-1111-4111-8111-111111111111",
        }),
    );

    try std.testing.expectEqual(@as(usize, 0), state.output.items.len);
    try std.testing.expectEqual(@as(u64, 1), client.next_id);
}

test "local policy covers every generated provider authority descriptor" {
    const state = try RecordingConnection.create("");
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    var provider_commands: usize = 0;
    for (protocol.commands) |command| {
        if (!std.mem.eql(u8, command.authority, "provider-authority")) continue;
        provider_commands += 1;
        try std.testing.expectError(
            error.ProviderAuthorityDenied,
            client.callUnchecked(
                struct {},
                .{
                    .name = command.name,
                    .authority = command.authority,
                },
                .{},
            ),
        );
    }

    try std.testing.expectEqual(@as(usize, 3), provider_commands);
    try std.testing.expectEqual(@as(usize, 0), state.output.items.len);
}

test "default local policy permits a generated local-admin command" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":10,\"capabilities\":[]}}\n" ++
            "{\"id\":2,\"ok\":true,\"data\":{}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    var result = try protocol.pairingResponse(&client, .{
        .approve = false,
        .request = 7,
    });
    defer result.deinit();

    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"pairing-response\"",
    ) != null);
}

test "explicit provider authority policy permits provider write" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":10,\"capabilities\":[" ++
            "\"provider-managed-workspace-authority-v2\"]}}\n" ++
            "{\"id\":2,\"ok\":true,\"data\":{}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{ .authority_policy = .provider_authority },
    );
    defer client.deinit();

    var result = try protocol.markWorkspacesProviderManaged(&client, .{
        .authority = "secret",
    });
    defer result.deinit();

    try std.testing.expect(state.output.items.len > 0);
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"mark-workspaces-provider-managed\"",
    ) != null);
}

test "old protocol rejects a generated command before its write" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":6,\"capabilities\":[]}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.UnsupportedProtocol,
        protocol.readScrollback(&client, .{
            .surface = 1,
            .start = 0,
            .count = 1,
        }),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"identify\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"read-scrollback\"",
    ) == null);
}

test "missing capability rejects a generated command before its write" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":10,\"capabilities\":[]}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.MissingCapability,
        protocol.createWorkspace(&client, .{}),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"create-workspace\"",
    ) == null);
}

test "field protocol requirement applies only when the field is present" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":6,\"capabilities\":[]}}\n" ++
            "{\"id\":2,\"ok\":true,\"data\":{}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.UnsupportedFieldProtocol,
        protocol.send(&client, .{
            .surface = 1,
            .paste = true,
        }),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"send\"",
    ) == null);

    var result = try protocol.send(&client, .{ .surface = 1 });
    defer result.deinit();
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"send\"",
    ) != null);
}

test "missing field capability rejects a stream before its write" {
    const state = try RecordingConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{" ++
            "\"protocol\":10,\"capabilities\":[]}}\n",
    );
    var client = client_module.Client.init(
        std.testing.allocator,
        client_module.Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.MissingFieldCapability,
        protocol.attachSurface(&client, .{
            .surface = 1,
            .cols = .{ .value = 80 },
            .rows = .{ .value = 24 },
        }),
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        state.output.items,
        "\"cmd\":\"attach-surface\"",
    ) == null);
}

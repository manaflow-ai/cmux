const std = @import("std");
const client_module = @import("client.zig");
const protocol = @import("generated/protocol.zig");

const DedicatedServer = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    failure: ?anyerror = null,

    fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !*DedicatedServer {
        const self = try allocator.create(DedicatedServer);
        errdefer allocator.destroy(self);
        const address = try std.net.Address.initUnix(path);
        self.* = .{
            .allocator = allocator,
            .listener = try address.listen(.{}),
        };
        return self;
    }

    fn deinit(self: *DedicatedServer) void {
        const allocator = self.allocator;
        self.listener.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *DedicatedServer) void {
        self.run() catch |err| {
            self.failure = err;
        };
    }

    fn run(self: *DedicatedServer) !void {
        const command_connection = try self.listener.accept();
        defer command_connection.stream.close();
        const stream_connection = try self.listener.accept();
        defer stream_connection.stream.close();

        try self.respondIdentify(stream_connection.stream);
        var subscribe = try self.receive(stream_connection.stream, "subscribe");
        defer subscribe.deinit();
        try self.respond(
            stream_connection.stream,
            try requestId(subscribe.value),
            .{},
        );

        try self.respondIdentify(command_connection.stream);
        var ping = try self.receive(command_connection.stream, "ping");
        defer ping.deinit();
        try self.respond(
            command_connection.stream,
            try requestId(ping.value),
            .{
                .ok = true,
                .protocol = @as(u32, 10),
                .version = "test",
            },
        );
    }

    fn respondIdentify(
        self: *DedicatedServer,
        stream: std.net.Stream,
    ) !void {
        var identify = try self.receive(stream, "identify");
        defer identify.deinit();
        const no_capabilities = [_][]const u8{};
        try self.respond(
            stream,
            try requestId(identify.value),
            .{
                .protocol = @as(u32, 10),
                .capabilities = &no_capabilities,
            },
        );
    }

    fn receive(
        self: *DedicatedServer,
        stream: std.net.Stream,
        expected_command: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        const line = try readLineAlloc(self.allocator, stream);
        defer self.allocator.free(line);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            line,
            .{},
        );
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.ExpectedObject;
        const command = parsed.value.object.get("cmd") orelse
            return error.MissingCommand;
        if (command != .string or
            !std.mem.eql(u8, command.string, expected_command))
        {
            return error.UnexpectedCommand;
        }
        return parsed;
    }

    fn respond(
        self: *DedicatedServer,
        stream: std.net.Stream,
        id: u64,
        data: anytype,
    ) !void {
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .id = id, .ok = true, .data = data },
            .{},
        );
        defer self.allocator.free(encoded);
        try stream.writeAll(encoded);
        try stream.writeAll("\n");
    }
};

test "stream helper keeps the command client usable" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const server = try DedicatedServer.create(std.testing.allocator, path);
    defer server.deinit();
    const thread = try std.Thread.spawn(.{}, DedicatedServer.threadMain, .{server});
    var joined = false;
    defer if (!joined) thread.join();

    var command_client = try client_module.Client.connect(
        std.testing.allocator,
        .{ .socket_path = path },
    );
    defer command_client.deinit();
    var stream_client = try command_client.openStreamClient();
    defer stream_client.deinit();

    var stream = try protocol.subscribe(&stream_client, .{});
    defer stream.deinit();
    try std.testing.expect(stream_client.streaming);
    try std.testing.expect(!command_client.streaming);

    var ping = try protocol.ping(&command_client, .{});
    defer ping.deinit();
    try std.testing.expect(ping.value.ok);

    thread.join();
    joined = true;
    if (server.failure) |failure| return failure;
}

fn socketPath(
    allocator: std.mem.Allocator,
    temp: *const std.testing.TmpDir,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/dedicated.sock",
        .{&temp.sub_path},
    );
}

fn readLineAlloc(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    while (bytes.items.len <= 64 * 1024) {
        var byte: [1]u8 = undefined;
        const count = try stream.read(&byte);
        if (count == 0) return error.ConnectionClosed;
        if (byte[0] == '\n') return bytes.toOwnedSlice(allocator);
        try bytes.append(allocator, byte[0]);
    }
    return error.FrameTooLarge;
}

fn requestId(value: std.json.Value) !u64 {
    const raw = value.object.get("id") orelse return error.MissingRequestId;
    return switch (raw) {
        .integer => |number| std.math.cast(u64, number) orelse
            error.InvalidRequestId,
        .number_string => |number| try std.fmt.parseInt(u64, number, 10),
        else => error.InvalidRequestId,
    };
}

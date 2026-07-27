const std = @import("std");
const cmux = @import("cmux_tui");
const provider = @import("provider_controller");

const authority = "provider-secret";
const seed_key = "11111111-1111-4111-8111-111111111111";
const created_key = "22222222-2222-4222-8222-222222222222";
const registry_id = "registry-test";
const generation = "generation-test";
const EmptyScreen = struct {};

const Scenario = enum {
    happy,
    authority_error,
    old_protocol,
    missing_capability,
    omitted_capabilities,
    stale_create,
    init_only,
    revision_gap,
};

const FakeServer = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    scenario: Scenario,
    failure: ?anyerror = null,
    requests_seen: usize = 0,

    fn create(
        allocator: std.mem.Allocator,
        path: []const u8,
        scenario: Scenario,
    ) !*FakeServer {
        const self = try allocator.create(FakeServer);
        errdefer allocator.destroy(self);
        const address = try std.net.Address.initUnix(path);
        self.* = .{
            .allocator = allocator,
            .listener = try address.listen(.{}),
            .scenario = scenario,
        };
        return self;
    }

    fn deinit(self: *FakeServer) void {
        const allocator = self.allocator;
        self.listener.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *FakeServer) void {
        self.run() catch |err| {
            self.failure = err;
        };
    }

    fn run(self: *FakeServer) !void {
        const connection = try self.listener.accept();
        defer connection.stream.close();
        switch (self.scenario) {
            .happy => try self.runHappy(connection.stream),
            .authority_error => try self.runAuthorityError(connection.stream),
            .old_protocol => try self.runProtocolError(
                connection.stream,
                8,
                true,
            ),
            .missing_capability => try self.runProtocolError(
                connection.stream,
                10,
                false,
            ),
            .omitted_capabilities => try self.handleIdentifyWithoutCapabilities(
                connection.stream,
                10,
            ),
            .stale_create => try self.runStaleCreate(connection.stream),
            .init_only => try self.runInitialize(connection.stream),
            .revision_gap => try self.runRevisionGap(connection.stream),
        }
    }

    fn runHappy(self: *FakeServer, stream: std.net.Stream) !void {
        try self.runInitialize(stream);

        var create_request = try self.receive(stream, "create-workspace");
        defer create_request.deinit();
        const create_object = create_request.value.object;
        try expectString(create_object, "name", "worker");
        try expectString(create_object, "key", created_key);
        try expectString(create_object, "origin", provider.mutation_origin);
        try expectString(create_object, "mutation_id", "mutation-create-1");
        try expectString(create_object, "expected_generation", generation);
        try expectInteger(create_object, "expected_revision", 7);
        try self.respond(stream, try requestId(create_request.value), .{
            .workspace = @as(u64, 42),
            .key = created_key,
            .index = @as(u64, 1),
            .workspace_revision = @as(u64, 8),
            .replayed = false,
            .registry_id = registry_id,
            .generation = generation,
        });

        var rename = try self.receive(
            stream,
            "rename-provider-managed-workspace",
        );
        defer rename.deinit();
        const rename_object = rename.value.object;
        try expectString(rename_object, "authority", authority);
        try expectInteger(rename_object, "workspace", 42);
        try expectString(rename_object, "key", created_key);
        try expectString(rename_object, "name", "production");
        try expectAbsent(rename_object, "expected_revision");
        try self.respond(stream, try requestId(rename.value), .{
            .workspace = @as(u64, 42),
            .key = created_key,
            .workspace_revision = @as(u64, 9),
        });

        var close = try self.receive(
            stream,
            "close-provider-managed-workspace",
        );
        defer close.deinit();
        const close_object = close.value.object;
        try expectString(close_object, "authority", authority);
        try expectInteger(close_object, "workspace", 42);
        try expectString(close_object, "key", created_key);
        try expectAbsent(close_object, "expected_revision");
        try self.respond(stream, try requestId(close.value), .{
            .workspace = @as(u64, 42),
            .key = created_key,
            .workspace_revision = @as(u64, 10),
        });
    }

    fn runInitialize(self: *FakeServer, stream: std.net.Stream) !void {
        try self.handleIdentify(stream, 10, true);
        var mark = try self.receive(
            stream,
            "mark-workspaces-provider-managed",
        );
        defer mark.deinit();
        try expectString(mark.value.object, "authority", authority);
        try self.respond(stream, try requestId(mark.value), struct {}{});
        try self.handleList(stream);
    }

    fn runAuthorityError(self: *FakeServer, stream: std.net.Stream) !void {
        try self.handleIdentify(stream, 10, true);
        var mark = try self.receive(
            stream,
            "mark-workspaces-provider-managed",
        );
        defer mark.deinit();
        try expectString(mark.value.object, "authority", "wrong-secret");
        try self.respondError(
            stream,
            try requestId(mark.value),
            "invalid provider workspace authority",
        );
    }

    fn runProtocolError(
        self: *FakeServer,
        stream: std.net.Stream,
        protocol: u32,
        include_provider_capability: bool,
    ) !void {
        try self.handleIdentify(
            stream,
            protocol,
            include_provider_capability,
        );
    }

    fn runStaleCreate(self: *FakeServer, stream: std.net.Stream) !void {
        try self.runInitialize(stream);
        var create_request = try self.receive(stream, "create-workspace");
        defer create_request.deinit();
        try expectInteger(create_request.value.object, "expected_revision", 7);
        try self.respondError(
            stream,
            try requestId(create_request.value),
            "workspace revision conflict: expected 7, current 8",
        );
    }

    fn runRevisionGap(self: *FakeServer, stream: std.net.Stream) !void {
        try self.runInitialize(stream);
        var rename = try self.receive(
            stream,
            "rename-provider-managed-workspace",
        );
        defer rename.deinit();
        try expectInteger(rename.value.object, "workspace", 41);
        try expectString(rename.value.object, "key", seed_key);
        try self.respond(stream, try requestId(rename.value), .{
            .workspace = @as(u64, 41),
            .key = seed_key,
            .workspace_revision = @as(u64, 9),
        });
    }

    fn handleIdentify(
        self: *FakeServer,
        stream: std.net.Stream,
        protocol: u32,
        include_provider_capability: bool,
    ) !void {
        var request = try self.receive(stream, "identify");
        defer request.deinit();
        const provider_capabilities = [_][]const u8{
            "workspace-registry-v1",
            provider.provider_capability,
        };
        const base_capabilities = [_][]const u8{"workspace-registry-v1"};
        const capabilities: []const []const u8 =
            if (include_provider_capability)
                &provider_capabilities
            else
                &base_capabilities;
        try self.respond(stream, try requestId(request.value), .{
            .app = "cmux-tui",
            .version = "0.4.0-test",
            .protocol = protocol,
            .capabilities = capabilities,
            .session = "provider-test",
            .pid = @as(u32, 1234),
            .registry_id = registry_id,
            .generation = generation,
            .workspace_revision = @as(u64, 7),
            .terminal_revision = @as(u64, 0),
            .daemon_handoff = @as(i64, 1),
        });
    }

    fn handleIdentifyWithoutCapabilities(
        self: *FakeServer,
        stream: std.net.Stream,
        protocol: u32,
    ) !void {
        var request = try self.receive(stream, "identify");
        defer request.deinit();
        try self.respond(stream, try requestId(request.value), .{
            .app = "cmux-tui",
            .version = "0.4.0-test",
            .protocol = protocol,
            .session = "provider-test",
            .pid = @as(u32, 1234),
            .registry_id = registry_id,
            .generation = generation,
            .workspace_revision = @as(u64, 7),
            .terminal_revision = @as(u64, 0),
            .daemon_handoff = @as(i64, 1),
        });
    }

    fn handleList(self: *FakeServer, stream: std.net.Stream) !void {
        var request = try self.receive(stream, "list-workspaces");
        defer request.deinit();
        const empty_screens = [_]EmptyScreen{};
        const workspaces = [_]struct {
            active: bool,
            id: u64,
            key: []const u8,
            name: []const u8,
            screens: []const EmptyScreen,
            short_id: []const u8,
        }{.{
            .active = true,
            .id = 41,
            .key = seed_key,
            .name = "seed",
            .screens = &empty_screens,
            .short_id = "workspace:1",
        }};
        try self.respond(stream, try requestId(request.value), .{
            .registry_id = registry_id,
            .generation = generation,
            .workspace_revision = @as(u64, 7),
            .terminal_revision = @as(u64, 0),
            .pane_revision = @as(u64, 0),
            .workspaces = &workspaces,
        });
    }

    fn receive(
        self: *FakeServer,
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
        try expectString(parsed.value.object, "cmd", expected_command);
        self.requests_seen += 1;
        return parsed;
    }

    fn respond(
        self: *FakeServer,
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

    fn respondError(
        self: *FakeServer,
        stream: std.net.Stream,
        id: u64,
        message: []const u8,
    ) !void {
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{ .id = id, .ok = false, .@"error" = message },
            .{},
        );
        defer self.allocator.free(encoded);
        try stream.writeAll(encoded);
        try stream.writeAll("\n");
    }
};

test "public SDK drives provider lifecycle over a Unix socket" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);

    const fake = try FakeServer.create(std.testing.allocator, path, .happy);
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = authority },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try controller.initialize();
    try std.testing.expectEqualStrings(
        registry_id,
        try controller.registryId(),
    );
    try std.testing.expectEqualStrings(
        generation,
        try controller.generationId(),
    );
    try std.testing.expectEqual(@as(u64, 7), try controller.workspaceRevision());
    try std.testing.expectEqual(@as(usize, 1), (try controller.workspaces()).len);

    const created = try controller.createWorkspace(
        try controller.workspaceRevision(),
        "worker",
        created_key,
        "mutation-create-1",
    );
    try std.testing.expectEqual(@as(u64, 42), created.workspace);
    try std.testing.expectEqual(@as(u64, 8), created.workspace_revision);
    try std.testing.expectEqual(@as(usize, 2), (try controller.workspaces()).len);

    const renamed = try controller.renameWorkspace(
        try controller.workspaceRevision(),
        created.workspace,
        created_key,
        "production",
    );
    try std.testing.expectEqual(@as(u64, 9), renamed.workspace_revision);
    try std.testing.expectEqualStrings(
        "production",
        (try controller.workspaces())[1].name,
    );

    const closed = try controller.closeWorkspace(
        try controller.workspaceRevision(),
        created.workspace,
        created_key,
    );
    try std.testing.expectEqual(@as(u64, 10), closed.workspace_revision);
    try std.testing.expectEqual(@as(usize, 1), (try controller.workspaces()).len);

    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 6), fake.requests_seen);
}

test "authority error preserves the remote message" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .authority_error,
    );
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = "wrong-secret" },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try std.testing.expectError(error.RemoteError, controller.initialize());
    try std.testing.expectEqualStrings(
        "invalid provider workspace authority",
        controller.lastRemoteError().?,
    );
    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 2), fake.requests_seen);
}

test "old protocol is rejected before authority is sent" {
    try expectInitializeError(.old_protocol, error.UnsupportedProtocol);
}

test "missing provider capability is rejected before authority is sent" {
    try expectInitializeError(
        .missing_capability,
        error.MissingProviderCapability,
    );
}

test "omitted capabilities are treated as an empty capability set" {
    try expectInitializeError(
        .omitted_capabilities,
        error.MissingProviderCapability,
    );
}

test "wire CAS conflict preserves revision and remote detail" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .stale_create,
    );
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = authority },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try controller.initialize();
    try std.testing.expectError(
        error.RemoteError,
        controller.createWorkspace(
            7,
            "worker",
            created_key,
            "mutation-create-1",
        ),
    );
    try std.testing.expectEqualStrings(
        "workspace revision conflict: expected 7, current 8",
        controller.lastRemoteError().?,
    );
    try std.testing.expectEqual(@as(u64, 7), try controller.workspaceRevision());

    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 4), fake.requests_seen);
}

test "local CAS blocks a stale provider rename without a wire request" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .init_only,
    );
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = authority },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try controller.initialize();
    try std.testing.expectError(
        error.LocalRevisionConflict,
        controller.renameWorkspace(6, 41, seed_key, "stale"),
    );
    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 3), fake.requests_seen);
}

test "provider revision discontinuity does not mutate local topology" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .revision_gap,
    );
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = authority },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try controller.initialize();
    try std.testing.expectError(
        error.RevisionDiscontinuity,
        controller.renameWorkspace(7, 41, seed_key, "renamed"),
    );
    try std.testing.expectEqual(@as(u64, 7), try controller.workspaceRevision());
    try std.testing.expectEqualStrings(
        "seed",
        (try controller.workspaces())[0].name,
    );
    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 4), fake.requests_seen);
}

test "controller deinit releases allocator-owned authority and topology" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .init_only,
    );
    defer fake.deinit();

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    var controller = try provider.ProviderController.connect(
        allocator,
        .{ .socket_path = path, .authority = authority },
    );
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    try controller.initialize();
    controller.deinit();
    thread.join();
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(.ok, debug_allocator.deinit());
}

fn expectInitializeError(scenario: Scenario, expected: anyerror) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(std.testing.allocator, path, scenario);
    defer fake.deinit();
    var controller = try provider.ProviderController.connect(
        std.testing.allocator,
        .{ .socket_path = path, .authority = authority },
    );
    errdefer controller.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer controller.deinit();

    try std.testing.expectError(expected, controller.initialize());
    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 1), fake.requests_seen);
}

fn socketPath(
    allocator: std.mem.Allocator,
    temp: *const std.testing.TmpDir,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/provider.sock",
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

fn expectString(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: []const u8,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    if (value != .string) return error.ExpectedString;
    if (!std.mem.eql(u8, value.string, expected)) return error.UnexpectedValue;
}

fn expectInteger(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: u64,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    const actual = switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse
            return error.ExpectedInteger,
        .number_string => |number| try std.fmt.parseInt(u64, number, 10),
        else => return error.ExpectedInteger,
    };
    if (actual != expected) return error.UnexpectedValue;
}

fn expectAbsent(object: std.json.ObjectMap, field: []const u8) !void {
    if (object.get(field) != null) return error.UnexpectedField;
}

test "consumer compiles against the public protocol inventory" {
    try std.testing.expectEqual(@as(usize, 83), cmux.protocol.command_count);
    try std.testing.expectEqual(@as(usize, 44), cmux.protocol.event_count);
    try std.testing.expectEqual(@as(u16, 10), cmux.protocol.mux_protocol);
}

const std = @import("std");
const client_module = @import("client.zig");
const provider = @import("provider.zig");

const authority = "provider-secret";
const seed_key = "11111111-1111-4111-8111-111111111111";
const created_key = "22222222-2222-4222-8222-222222222222";
const registry_id = "registry-test";
const generation = "generation-test";
const EmptyScreen = struct {};

const Scenario = enum {
    lifecycle,
    authority_error,
    old_protocol,
    missing_capability,
    revision_gap,
    init_only,
};

const ObservingAllocator = struct {
    child: std.mem.Allocator,
    target: ?[*]u8 = null,
    target_len: usize = 0,
    target_freed: bool = false,
    target_was_zero: bool = false,

    fn allocator(self: *ObservingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        if (self.target) |target| {
            if (memory.ptr == target and memory.len == self.target_len) {
                self.target_freed = true;
                self.target_was_zero = true;
                for (memory) |byte| {
                    if (byte != 0) {
                        self.target_was_zero = false;
                        break;
                    }
                }
            }
        }
        self.child.rawFree(memory, alignment, return_address);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
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
            .lifecycle => try self.runLifecycle(connection.stream),
            .authority_error => try self.runAuthorityError(connection.stream),
            .old_protocol => try self.handleIdentify(
                connection.stream,
                8,
                true,
            ),
            .missing_capability => try self.handleIdentify(
                connection.stream,
                10,
                false,
            ),
            .revision_gap => try self.runRevisionGap(connection.stream),
            .init_only => try self.runInitialize(connection.stream),
        }
    }

    fn runLifecycle(self: *FakeServer, stream: std.net.Stream) !void {
        try self.runInitialize(stream);
        try self.handleList(stream);

        var create_request = try self.receive(stream, "create-workspace");
        defer create_request.deinit();
        const create_object = create_request.value.object;
        try expectString(create_object, "name", "worker");
        try expectString(create_object, "key", created_key);
        try expectString(create_object, "origin", "test-provider");
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

        var rename_request = try self.receive(
            stream,
            "rename-provider-managed-workspace",
        );
        defer rename_request.deinit();
        const rename_object = rename_request.value.object;
        try expectString(rename_object, "authority", authority);
        try expectInteger(rename_object, "workspace", 42);
        try expectString(rename_object, "key", created_key);
        try expectString(rename_object, "name", "production");
        try expectAbsent(rename_object, "expected_revision");
        try self.respond(stream, try requestId(rename_request.value), .{
            .workspace = @as(u64, 42),
            .key = created_key,
            .workspace_revision = @as(u64, 9),
        });

        var close_request = try self.receive(
            stream,
            "close-provider-managed-workspace",
        );
        defer close_request.deinit();
        const close_object = close_request.value.object;
        try expectString(close_object, "authority", authority);
        try expectInteger(close_object, "workspace", 42);
        try expectString(close_object, "key", created_key);
        try expectAbsent(close_object, "expected_revision");
        try self.respond(stream, try requestId(close_request.value), .{
            .workspace = @as(u64, 42),
            .key = created_key,
            .workspace_revision = @as(u64, 10),
        });
    }

    fn runInitialize(self: *FakeServer, stream: std.net.Stream) !void {
        try self.handleIdentify(stream, 10, true);
        var mark_request = try self.receive(
            stream,
            "mark-workspaces-provider-managed",
        );
        defer mark_request.deinit();
        try expectString(mark_request.value.object, "authority", authority);
        try self.respond(
            stream,
            try requestId(mark_request.value),
            struct {}{},
        );
        try self.handleList(stream);
    }

    fn runAuthorityError(self: *FakeServer, stream: std.net.Stream) !void {
        try self.handleIdentify(stream, 10, true);
        var mark_request = try self.receive(
            stream,
            "mark-workspaces-provider-managed",
        );
        defer mark_request.deinit();
        try expectString(
            mark_request.value.object,
            "authority",
            "wrong-secret",
        );
        try self.respondError(
            stream,
            try requestId(mark_request.value),
            "invalid provider workspace authority",
        );
    }

    fn runRevisionGap(self: *FakeServer, stream: std.net.Stream) !void {
        try self.runInitialize(stream);
        var rename_request = try self.receive(
            stream,
            "rename-provider-managed-workspace",
        );
        defer rename_request.deinit();
        try expectInteger(rename_request.value.object, "workspace", 41);
        try expectString(rename_request.value.object, "key", seed_key);
        try self.respond(stream, try requestId(rename_request.value), .{
            .workspace = @as(u64, 41),
            .key = seed_key,
            .workspace_revision = @as(u64, 9),
        });
    }

    fn handleIdentify(
        self: *FakeServer,
        stream: std.net.Stream,
        protocol_version: u32,
        include_provider_capability: bool,
    ) !void {
        var request = try self.receive(stream, "identify");
        defer request.deinit();
        const provider_capabilities = [_][]const u8{
            provider.workspace_registry_capability,
            provider.provider_capability,
        };
        const base_capabilities = [_][]const u8{
            provider.workspace_registry_capability,
        };
        const capability_list: []const []const u8 =
            if (include_provider_capability)
                &provider_capabilities
            else
                &base_capabilities;
        try self.respond(stream, try requestId(request.value), .{
            .app = "cmux-tui",
            .version = "0.4.0-test",
            .protocol = protocol_version,
            .capabilities = capability_list,
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

test "ProviderClient drives the complete lifecycle over a Unix socket" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(
        std.testing.allocator,
        path,
        .lifecycle,
    );
    defer fake.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();

    var provider_client = try provider.ProviderClient.connect(
        std.testing.allocator,
        .{
            .authority = authority,
            .client = .{ .socket_path = path },
        },
    );
    defer provider_client.deinit();

    const initial = try provider_client.currentSnapshot();
    try std.testing.expectEqualStrings(registry_id, initial.registry_id);
    try std.testing.expectEqualStrings(generation, initial.generation);
    try std.testing.expectEqual(@as(u64, 7), initial.workspace_revision);
    try std.testing.expectEqual(@as(usize, 1), initial.workspaces.len);

    const refreshed = try provider_client.snapshot();
    try std.testing.expectEqual(@as(u64, 7), refreshed.workspace_revision);
    const created = try provider_client.createWorkspace(.{
        .expected_revision = refreshed.workspace_revision,
        .name = "worker",
        .key = created_key,
        .mutation_id = "mutation-create-1",
        .origin = "test-provider",
    });
    try std.testing.expectEqual(@as(u64, 42), created.workspace);
    try std.testing.expectEqual(@as(u64, 8), created.workspace_revision);

    const renamed = try provider_client.renameWorkspace(.{
        .expected_revision = created.workspace_revision,
        .workspace = created.workspace,
        .key = created_key,
        .name = "production",
    });
    try std.testing.expectEqual(@as(u64, 9), renamed.workspace_revision);
    try std.testing.expectEqualStrings(
        "production",
        (try provider_client.currentSnapshot()).workspaces[1].name,
    );

    const closed = try provider_client.closeWorkspace(.{
        .expected_revision = renamed.workspace_revision,
        .workspace = renamed.workspace,
        .key = created_key,
    });
    try std.testing.expectEqual(@as(u64, 10), closed.workspace_revision);
    try std.testing.expectEqual(
        @as(usize, 1),
        (try provider_client.currentSnapshot()).workspaces.len,
    );

    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 7), fake.requests_seen);
}

test "two-phase initialize transfers an authority error" {
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
    var provider_client = try provider.ProviderClient.open(
        std.testing.allocator,
        .{
            .authority = "wrong-secret",
            .client = .{ .socket_path = path },
        },
    );
    errdefer provider_client.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer provider_client.deinit();

    try std.testing.expectError(
        error.RemoteError,
        provider_client.initialize(),
    );
    var remote_error = provider_client.takeRemoteError() orelse
        return error.ExpectedRemoteError;
    defer remote_error.deinit();
    try std.testing.expectEqualStrings(
        "invalid provider workspace authority",
        remote_error.message,
    );
    try std.testing.expect(provider_client.takeRemoteError() == null);

    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 2), fake.requests_seen);
}

test "protocol and capability failures stop before authority transmission" {
    try expectInitializeError(.old_protocol, error.UnsupportedProtocol);
    try expectInitializeError(
        .missing_capability,
        error.MissingProviderCapability,
    );
}

test "local revision guard sends no provider mutation" {
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
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    var provider_client = try provider.ProviderClient.connect(
        std.testing.allocator,
        .{
            .authority = authority,
            .client = .{ .socket_path = path },
        },
    );
    defer provider_client.deinit();

    try std.testing.expectError(
        error.LocalRevisionConflict,
        provider_client.renameWorkspace(.{
            .expected_revision = 6,
            .workspace = 41,
            .key = seed_key,
            .name = "stale",
        }),
    );
    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 3), fake.requests_seen);
}

test "wire revision gap preserves the retained snapshot" {
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
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    var provider_client = try provider.ProviderClient.connect(
        std.testing.allocator,
        .{
            .authority = authority,
            .client = .{ .socket_path = path },
        },
    );
    defer provider_client.deinit();

    try std.testing.expectError(
        error.RevisionGap,
        provider_client.renameWorkspace(.{
            .expected_revision = 7,
            .workspace = 41,
            .key = seed_key,
            .name = "renamed",
        }),
    );
    const retained = try provider_client.currentSnapshot();
    try std.testing.expectEqual(@as(u64, 7), retained.workspace_revision);
    try std.testing.expectEqualStrings("seed", retained.workspaces[0].name);

    thread.join();
    joined = true;
    if (fake.failure) |failure| return failure;
    try std.testing.expectEqual(@as(usize, 4), fake.requests_seen);
}

test "owned Client wrapper and ProviderClient deinit are leak free" {
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
    var observing_allocator = ObservingAllocator{
        .child = debug_allocator.allocator(),
    };
    const allocator = observing_allocator.allocator();
    const base_client = try client_module.Client.connect(
        allocator,
        .{ .socket_path = path },
    );
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var provider_client = try provider.ProviderClient.fromOwnedClient(
        allocator,
        base_client,
        authority,
    );
    observing_allocator.target = provider_client.authority.ptr;
    observing_allocator.target_len = provider_client.authority.len;
    provider_client.deinit();
    thread.join();
    if (fake.failure) |failure| return failure;
    try std.testing.expect(observing_allocator.target_freed);
    try std.testing.expect(observing_allocator.target_was_zero);
    try std.testing.expectEqual(.ok, debug_allocator.deinit());
}

fn expectInitializeError(scenario: Scenario, expected: anyerror) !void {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try socketPath(std.testing.allocator, &temp);
    defer std.testing.allocator.free(path);
    const fake = try FakeServer.create(std.testing.allocator, path, scenario);
    defer fake.deinit();
    var provider_client = try provider.ProviderClient.open(
        std.testing.allocator,
        .{
            .authority = authority,
            .client = .{ .socket_path = path },
        },
    );
    errdefer provider_client.deinit();
    const thread = try std.Thread.spawn(.{}, FakeServer.threadMain, .{fake});
    var joined = false;
    defer if (!joined) thread.join();
    defer provider_client.deinit();

    try std.testing.expectError(expected, provider_client.initialize());
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

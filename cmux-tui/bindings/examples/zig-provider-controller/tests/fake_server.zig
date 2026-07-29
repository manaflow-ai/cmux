const std = @import("std");
const cmux = @import("cmux_tui");
const provider = @import("provider_controller");

const hex = "0123456789abcdef0123456789abcdef";
const provider_scope_text = "provider_scope_" ++ hex;
const session_text = "session_" ++ hex;
const other_session_text = "session_fedcba9876543210fedcba9876543210";
const workspace_text = "ws_" ++ hex;
const generation = "generation-provider-test";

const Scenario = enum {
    lifecycle,
    revision_conflict,
    wrong_scope,
    mark_only,
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
            .revision_conflict => try self.runRevisionConflict(
                connection.stream,
            ),
            .wrong_scope => try self.runWrongScope(connection.stream),
            .mark_only => try self.runMarkOnly(connection.stream),
        }
    }

    fn runLifecycle(self: *FakeServer, stream: std.net.Stream) !void {
        var mark = try self.receive(stream, "provider_workspace.mark");
        defer mark.deinit();
        try expectMutationRoute(mark.value, 10, "mark-1");
        const mark_params = try requestParams(mark.value);
        try expectBool(mark_params, "managed", true);
        try self.respondMutation(
            stream,
            try requestId(mark.value),
            workspaceSnapshot(session_text, "seed"),
            "11",
            false,
        );

        var rename = try self.receive(stream, "provider_workspace.rename");
        defer rename.deinit();
        try expectMutationRoute(rename.value, 11, "rename-1");
        try expectString(
            try requestParams(rename.value),
            "name",
            "production",
        );
        try self.respondMutation(
            stream,
            try requestId(rename.value),
            workspaceSnapshot(session_text, "production"),
            "12",
            false,
        );

        var clear_name = try self.receive(
            stream,
            "provider_workspace.rename",
        );
        defer clear_name.deinit();
        try expectMutationRoute(clear_name.value, 12, "clear-name-1");
        try expectNull(try requestParams(clear_name.value), "name");
        try self.respondMutation(
            stream,
            try requestId(clear_name.value),
            workspaceSnapshot(session_text, "seed"),
            "13",
            false,
        );

        var close = try self.receive(stream, "provider_workspace.close");
        defer close.deinit();
        try expectMutationRoute(close.value, 13, "close-1");
        try self.respondMutation(
            stream,
            try requestId(close.value),
            struct {}{},
            "14",
            false,
        );
    }

    fn runRevisionConflict(
        self: *FakeServer,
        stream: std.net.Stream,
    ) !void {
        var mark = try self.receive(stream, "provider_workspace.mark");
        defer mark.deinit();
        try expectMutationRoute(mark.value, 10, "mark-1");
        try self.respondMutation(
            stream,
            try requestId(mark.value),
            workspaceSnapshot(session_text, "seed"),
            "11",
            false,
        );

        var rename = try self.receive(stream, "provider_workspace.rename");
        defer rename.deinit();
        try expectMutationRoute(rename.value, 11, "rename-conflict");
        try self.respondError(
            stream,
            try requestId(rename.value),
            "revision.conflict",
            "workspace revision changed",
            .{ .expected = "11", .actual = "12" },
        );
    }

    fn runWrongScope(self: *FakeServer, stream: std.net.Stream) !void {
        var mark = try self.receive(stream, "provider_workspace.mark");
        defer mark.deinit();
        try expectMutationRoute(mark.value, 10, "mark-wrong");
        try self.respondMutation(
            stream,
            try requestId(mark.value),
            workspaceSnapshot(other_session_text, "wrong"),
            "11",
            false,
        );
    }

    fn runMarkOnly(self: *FakeServer, stream: std.net.Stream) !void {
        var mark = try self.receive(stream, "provider_workspace.mark");
        defer mark.deinit();
        try expectMutationRoute(mark.value, 10, "mark-leak");
        try self.respondMutation(
            stream,
            try requestId(mark.value),
            workspaceSnapshot(session_text, "owned-name"),
            "11",
            false,
        );
    }

    fn receive(
        self: *FakeServer,
        stream: std.net.Stream,
        expected_operation: []const u8,
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
        try expectString(
            parsed.value.object,
            "protocol",
            "cmux.protocol/1",
        );
        try expectString(parsed.value.object, "type", "request");
        try expectString(
            parsed.value.object,
            "operation",
            expected_operation,
        );
        self.requests_seen += 1;
        return parsed;
    }

    fn respondMutation(
        self: *FakeServer,
        stream: std.net.Stream,
        id: []const u8,
        value: anytype,
        revision: []const u8,
        replayed: bool,
    ) !void {
        try self.respond(stream, id, .{
            .value = value,
            .generation = generation,
            .revision = revision,
            .replayed = replayed,
        });
    }

    fn respond(
        self: *FakeServer,
        stream: std.net.Stream,
        id: []const u8,
        result: anytype,
    ) !void {
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{
                .protocol = "cmux.protocol/1",
                .type = "response",
                .id = id,
                .ok = true,
                .result = result,
            },
            .{},
        );
        defer self.allocator.free(encoded);
        try stream.writeAll(encoded);
        try stream.writeAll("\n");
    }

    fn respondError(
        self: *FakeServer,
        stream: std.net.Stream,
        id: []const u8,
        code: []const u8,
        message: []const u8,
        details: anytype,
    ) !void {
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            .{
                .protocol = "cmux.protocol/1",
                .type = "response",
                .id = id,
                .ok = false,
                .@"error" = .{
                    .code = code,
                    .message = message,
                    .details = details,
                    .retryable = false,
                },
            },
            .{},
        );
        defer self.allocator.free(encoded);
        try stream.writeAll(encoded);
        try stream.writeAll("\n");
    }
};

test "public resource API drives the provider workspace lifecycle" {
    var fixture = try Fixture.init(.lifecycle);
    defer fixture.deinit();
    var controller = try fixture.connect(std.testing.allocator);
    defer controller.deinit();

    const marked = try controller.markManaged(true, "mark-1");
    try std.testing.expectEqual(@as(u64, 11), marked.revision);
    try std.testing.expectEqualStrings("seed", controller.currentName().?);

    const renamed = try controller.rename("production", "rename-1");
    try std.testing.expectEqual(@as(u64, 12), renamed.revision);
    try std.testing.expectEqualStrings(
        "production",
        controller.currentName().?,
    );

    const cleared = try controller.rename(null, "clear-name-1");
    try std.testing.expectEqual(@as(u64, 13), cleared.revision);
    try std.testing.expectEqualStrings("seed", controller.currentName().?);

    const closed = try controller.closeWorkspace("close-1");
    try std.testing.expectEqual(@as(u64, 14), closed.revision);
    try std.testing.expect(controller.isClosed());
    try std.testing.expectError(
        error.WorkspaceAlreadyClosed,
        controller.closeWorkspace("close-again"),
    );

    try fixture.join();
    try std.testing.expectEqual(@as(usize, 4), fixture.server.requests_seen);
}

test "structured revision conflict remains available on the client" {
    var fixture = try Fixture.init(.revision_conflict);
    defer fixture.deinit();
    var controller = try fixture.connect(std.testing.allocator);
    defer controller.deinit();

    _ = try controller.markManaged(true, "mark-1");
    try std.testing.expectError(
        error.RemoteError,
        controller.rename("stale", "rename-conflict"),
    );
    try std.testing.expectEqual(@as(u64, 11), controller.currentRevision());
    const remote = controller.lastResourceError().?;
    try std.testing.expectEqualStrings("revision.conflict", remote.code);
    try std.testing.expectEqualStrings(
        "workspace revision changed",
        remote.message,
    );
    switch (remote.details) {
        .revision_conflict => |details| {
            try std.testing.expectEqual(@as(u64, 11), details.expected);
            try std.testing.expectEqual(@as(u64, 12), details.actual);
        },
        else => return error.UnexpectedResourceErrorDetails,
    }

    try fixture.join();
    try std.testing.expectEqual(@as(usize, 2), fixture.server.requests_seen);
}

test "mismatched typed snapshot does not advance controller state" {
    var fixture = try Fixture.init(.wrong_scope);
    defer fixture.deinit();
    var controller = try fixture.connect(std.testing.allocator);
    defer controller.deinit();

    try std.testing.expectError(
        error.SnapshotScopeMismatch,
        controller.markManaged(true, "mark-wrong"),
    );
    try std.testing.expectEqual(@as(u64, 10), controller.currentRevision());
    try std.testing.expect(controller.currentName() == null);

    try fixture.join();
    try std.testing.expectEqual(@as(usize, 1), fixture.server.requests_seen);
}

test "controller releases copied generation and workspace name" {
    var fixture = try Fixture.init(.mark_only);
    defer fixture.deinit();

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    var controller = try fixture.connect(allocator);
    _ = try controller.markManaged(true, "mark-leak");
    controller.deinit();
    try fixture.join();
    try std.testing.expectEqual(.ok, debug_allocator.deinit());
}

test "opaque IDs reject cross-resource and malformed values" {
    try std.testing.expectError(
        error.InvalidResourceId,
        cmux.WorkspaceId.parse(session_text),
    );
    try std.testing.expectError(
        error.InvalidResourceId,
        cmux.ProviderScopeId.parse("provider_scope_NOT_HEX"),
    );
}

const Fixture = struct {
    temp: std.testing.TmpDir,
    path: []u8,
    server: *FakeServer,
    thread: std.Thread,
    joined: bool = false,

    fn init(scenario: Scenario) !Fixture {
        var temp = std.testing.tmpDir(.{});
        errdefer temp.cleanup();
        const path = try socketPath(std.testing.allocator, &temp);
        errdefer std.testing.allocator.free(path);
        const server = try FakeServer.create(
            std.testing.allocator,
            path,
            scenario,
        );
        errdefer server.deinit();
        const thread = try std.Thread.spawn(
            .{},
            FakeServer.threadMain,
            .{server},
        );
        return .{
            .temp = temp,
            .path = path,
            .server = server,
            .thread = thread,
        };
    }

    fn connect(
        self: *Fixture,
        allocator: std.mem.Allocator,
    ) !provider.ProviderController {
        return provider.ProviderController.connect(allocator, .{
            .socket_path = self.path,
            .provider_scope_id = try cmux.ProviderScopeId.parse(
                provider_scope_text,
            ),
            .session_id = try cmux.SessionId.parse(session_text),
            .workspace_id = try cmux.WorkspaceId.parse(workspace_text),
            .revision = 10,
        });
    }

    fn join(self: *Fixture) !void {
        if (!self.joined) {
            self.thread.join();
            self.joined = true;
        }
        if (self.server.failure) |failure| return failure;
    }

    fn deinit(self: *Fixture) void {
        if (!self.joined) self.thread.join();
        self.server.deinit();
        std.testing.allocator.free(self.path);
        self.temp.cleanup();
        self.* = undefined;
    }
};

fn workspaceSnapshot(
    session_id: []const u8,
    name: []const u8,
) struct {
    id: []const u8,
    session_id: []const u8,
    name: []const u8,
    index: u32,
    focused: bool,
} {
    return .{
        .id = workspace_text,
        .session_id = session_id,
        .name = name,
        .index = 0,
        .focused = true,
    };
}

fn socketPath(
    allocator: std.mem.Allocator,
    temp: *const std.testing.TmpDir,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/provider-resource.sock",
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

fn requestId(value: std.json.Value) ![]const u8 {
    const raw = value.object.get("id") orelse return error.MissingRequestId;
    return switch (raw) {
        .string => |text| text,
        else => error.InvalidRequestId,
    };
}

fn requestParams(value: std.json.Value) !std.json.ObjectMap {
    const raw = value.object.get("params") orelse return error.MissingParams;
    return switch (raw) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn expectMutationRoute(
    request: std.json.Value,
    revision: u64,
    idempotency_key: []const u8,
) !void {
    try expectString(
        request.object,
        "idempotency_key",
        idempotency_key,
    );
    const params = try requestParams(request);
    try expectString(params, "provider_scope", provider_scope_text);
    try expectString(params, "machine", "current");
    try expectString(params, "session", session_text);
    try expectString(params, "workspace", workspace_text);
    try expectDecimal(params, "expected_revision", revision);
}

fn expectString(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: []const u8,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    if (value != .string) return error.ExpectedString;
    if (!std.mem.eql(u8, value.string, expected)) {
        return error.UnexpectedValue;
    }
}

fn expectBool(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: bool,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    if (value != .bool or value.bool != expected) {
        return error.UnexpectedValue;
    }
}

fn expectNull(
    object: std.json.ObjectMap,
    field: []const u8,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    if (value != .null) return error.ExpectedNull;
}

fn expectDecimal(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: u64,
) !void {
    const value = object.get(field) orelse return error.MissingField;
    const actual = switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse
            return error.ExpectedInteger,
        .number_string => |number| try std.fmt.parseInt(u64, number, 10),
        .string => |number| try std.fmt.parseInt(u64, number, 10),
        else => return error.ExpectedInteger,
    };
    if (actual != expected) return error.UnexpectedValue;
}

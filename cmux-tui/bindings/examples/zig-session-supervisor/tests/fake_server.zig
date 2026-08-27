const std = @import("std");
const cmux = @import("cmux_tui");
const supervisor_api = @import("session_supervisor");

const hex_a = "11111111111111111111111111111111";
const hex_b = "22222222222222222222222222222222";
const hex_c = "33333333333333333333333333333333";
const hex_d = "44444444444444444444444444444444";
const hex_e = "55555555555555555555555555555555";
const hex_f = "66666666666666666666666666666666";
const machine_text = "machine_" ++ hex_a;
const session_text = "session_" ++ hex_b;
const workspace_text = "ws_" ++ hex_c;
const duplicate_workspace_text = "ws_" ++ hex_d;
const screen_text = "screen_" ++ hex_d;
const pane_text = "pane_" ++ hex_e;
const tab_text = "tab_" ++ hex_f;
const terminal_text = "term_" ++ hex_a;
const generation = "generation-session-supervisor";
const delayed_event_wait_ms: u64 = 75;

const Scenario = enum {
    lifecycle,
    duplicate_workspace,
    delayed_event,
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
        self.run() catch |failure| {
            self.failure = failure;
        };
    }

    fn run(self: *FakeServer) !void {
        const control = try self.listener.accept();
        defer control.stream.close();
        switch (self.scenario) {
            .lifecycle => try self.runLifecycle(control.stream),
            .duplicate_workspace => try self.runDuplicateWorkspace(
                control.stream,
            ),
            .delayed_event => try self.runDelayedEvent(control.stream),
        }
    }

    fn runLifecycle(
        self: *FakeServer,
        control: std.net.Stream,
    ) !void {
        try self.respondDiscovery(control, false, false);

        var create_1 = try self.receive(control, "workspace.create");
        defer create_1.deinit();
        try expectRoute(create_1.value, true, true, false);
        try expectIdempotency(create_1.value, "demo:workspace:1");
        if ((try requestParams(create_1.value)).get(
            "expected_revision",
        ) != null) {
            return error.UnexpectedRevision;
        }
        const create_1_params = try requestParams(create_1.value);
        try expectString(create_1_params, "name", "ci");
        try expectString(create_1_params, "initial_content", "empty");
        try expectString(
            create_1_params,
            "correlation_key",
            "demo:workspace",
        );
        try self.respondIndeterminate(
            control,
            try requestId(create_1.value),
            "workspace.create",
            "demo:workspace:1",
        );

        var resolve_workspace = try self.receive(
            control,
            "session.creation.resolve",
        );
        defer resolve_workspace.deinit();
        try expectRoute(
            resolve_workspace.value,
            true,
            true,
            false,
        );
        try expectString(
            try requestParams(resolve_workspace.value),
            "correlation_key",
            "demo:workspace",
        );
        try self.respond(
            control,
            try requestId(resolve_workspace.value),
            .{
                .correlation_key = "demo:workspace",
                .state = "not_applied",
                .recovery = "retry_new_idempotency_key",
                .operation = "workspace.create",
                .idempotency_key = "demo:workspace:1",
            },
        );

        var create_2 = try self.receive(control, "workspace.create");
        defer create_2.deinit();
        try expectRoute(create_2.value, true, true, false);
        try expectIdempotency(create_2.value, "demo:workspace:2");
        if ((try requestParams(create_2.value)).get(
            "expected_revision",
        ) != null) {
            return error.UnexpectedRevision;
        }
        try expectString(
            try requestParams(create_2.value),
            "correlation_key",
            "demo:workspace",
        );
        try self.respondMutation(
            control,
            try requestId(create_2.value),
            .{
                .kind = "workspace",
                .workspace_id = workspace_text,
            },
            11,
            false,
        );

        var run_request = try self.receive(control, "workspace.run");
        defer run_request.deinit();
        try expectRoute(run_request.value, true, true, true);
        try expectMutation(run_request.value, 11, "demo:run:1");
        const run_params = try requestParams(run_request.value);
        try expectString(
            run_params,
            "correlation_key",
            "demo:run",
        );
        try expectArgv(run_params, &.{ "printf", "hello world" });
        if (run_params.get("shell") != null) {
            return error.UnexpectedShellCommand;
        }
        try self.respondIndeterminate(
            control,
            try requestId(run_request.value),
            "workspace.run",
            "demo:run:1",
        );

        var resolve_run = try self.receive(
            control,
            "session.creation.resolve",
        );
        defer resolve_run.deinit();
        try expectRoute(resolve_run.value, true, true, false);
        try expectString(
            try requestParams(resolve_run.value),
            "correlation_key",
            "demo:run",
        );
        try self.respond(
            control,
            try requestId(resolve_run.value),
            .{
                .correlation_key = "demo:run",
                .state = "created",
                .recovery = "none",
                .operation = "workspace.run",
                .idempotency_key = "demo:run:1",
                .created_path = terminalPath(),
                .generation = generation,
                .revision = "12",
            },
        );

        var wait_pending = try self.receive(
            control,
            "terminal.wait_exit",
        );
        defer wait_pending.deinit();
        try expectRoute(wait_pending.value, true, true, false);
        const pending_params = try requestParams(wait_pending.value);
        try expectString(pending_params, "terminal", terminal_text);
        try expectString(pending_params, "timeout_ms", "250");
        try self.respond(
            control,
            try requestId(wait_pending.value),
            .{
                .state = "pending",
                .terminal_id = terminal_text,
                .lifecycle = "running",
                .revision = "12",
            },
        );

        var wait_exit = try self.receive(
            control,
            "terminal.wait_exit",
        );
        defer wait_exit.deinit();
        try expectRoute(wait_exit.value, true, true, false);
        const wait_params = try requestParams(wait_exit.value);
        try expectString(wait_params, "terminal", terminal_text);
        try expectString(wait_params, "timeout_ms", "250");
        try self.respond(
            control,
            try requestId(wait_exit.value),
            .{
                .state = "exited",
                .terminal_id = terminal_text,
                .lifecycle = "exited",
                .outcome = .{
                    .kind = "exit",
                    .code = 0,
                },
                .exited_at = "123456",
                .revision = "13",
            },
        );

        const event_connection = try self.listener.accept();
        defer event_connection.stream.close();
        try self.serveEvent(event_connection.stream, 0);
    }

    fn runDuplicateWorkspace(
        self: *FakeServer,
        control: std.net.Stream,
    ) !void {
        try self.respondDiscovery(control, true, false);
    }

    fn runDelayedEvent(
        self: *FakeServer,
        control: std.net.Stream,
    ) !void {
        try self.respondDiscovery(control, false, true);
        const event_connection = try self.listener.accept();
        defer event_connection.stream.close();
        try self.serveEvent(
            event_connection.stream,
            delayed_event_wait_ms,
        );
    }

    fn respondDiscovery(
        self: *FakeServer,
        control: std.net.Stream,
        duplicate_workspace: bool,
        existing_workspace: bool,
    ) !void {
        var machines = try self.receive(control, "machine.list");
        defer machines.deinit();
        try self.respond(
            control,
            try requestId(machines.value),
            [_]MachineSnapshot{machineSnapshot()},
        );

        var sessions = try self.receive(control, "session.list");
        defer sessions.deinit();
        try expectRoute(sessions.value, true, false, false);
        try self.respond(
            control,
            try requestId(sessions.value),
            [_]SessionSnapshot{sessionSnapshot()},
        );

        var workspaces = try self.receive(control, "workspace.list");
        defer workspaces.deinit();
        try expectRoute(workspaces.value, true, true, false);
        if (duplicate_workspace) {
            try self.respond(
                control,
                try requestId(workspaces.value),
                [_]WorkspaceSnapshot{
                    workspaceSnapshot(workspace_text, "ci", 0),
                    workspaceSnapshot(
                        duplicate_workspace_text,
                        "ci",
                        1,
                    ),
                },
            );
        } else if (existing_workspace) {
            try self.respond(
                control,
                try requestId(workspaces.value),
                [_]WorkspaceSnapshot{
                    workspaceSnapshot(workspace_text, "ci", 0),
                },
            );
        } else {
            try self.respond(
                control,
                try requestId(workspaces.value),
                [_]WorkspaceSnapshot{},
            );
        }
    }

    fn serveEvent(
        self: *FakeServer,
        stream: std.net.Stream,
        delay_ms: u64,
    ) !void {
        var open = try self.receive(stream, "session.events");
        defer open.deinit();
        try expectRoute(open.value, true, true, false);
        const open_params = try requestParams(open.value);
        const stream_id = try objectString(open_params, "stream_id");
        try self.respond(
            stream,
            try requestId(open.value),
            .{ .stream_id = stream_id },
        );
        if (delay_ms > 0) {
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
        try self.send(
            stream,
            .{
                .protocol = "cmux.protocol/2",
                .type = "stream_item",
                .stream_id = stream_id,
                .sequence = "1",
                .cursor = .{
                    .generation = generation,
                    .revision = "13",
                },
                .item = .{
                    .kind = "supervisor.heartbeat",
                    .healthy = true,
                },
            },
        );

        var cancel = try self.receive(stream, "stream.cancel");
        defer cancel.deinit();
        try expectRoute(cancel.value, true, true, false);
        try expectString(
            try requestParams(cancel.value),
            "stream",
            stream_id,
        );
        try self.respond(
            stream,
            try requestId(cancel.value),
            struct {}{},
        );
        try self.send(
            stream,
            .{
                .protocol = "cmux.protocol/2",
                .type = "stream_end",
                .stream_id = stream_id,
                .reason = "canceled",
                .cursor = .{
                    .generation = generation,
                    .revision = "13",
                },
            },
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
            "cmux.protocol/2",
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
        revision: u64,
        replayed: bool,
    ) !void {
        const revision_text = try std.fmt.allocPrint(
            self.allocator,
            "{d}",
            .{revision},
        );
        defer self.allocator.free(revision_text);
        try self.respond(stream, id, .{
            .value = value,
            .generation = generation,
            .revision = revision_text,
            .replayed = replayed,
        });
    }

    fn respondIndeterminate(
        self: *FakeServer,
        stream: std.net.Stream,
        id: []const u8,
        operation: []const u8,
        idempotency_key: []const u8,
    ) !void {
        try self.send(stream, .{
            .protocol = "cmux.protocol/2",
            .type = "response",
            .id = id,
            .ok = false,
            .@"error" = .{
                .code = "mutation.indeterminate",
                .message = "result requires correlation lookup",
                .details = .{
                    .idempotency_key = idempotency_key,
                    .operation = operation,
                    .recovery = "inspect_state_then_retry_with_new_key",
                },
                .retryable = false,
            },
        });
    }

    fn respond(
        self: *FakeServer,
        stream: std.net.Stream,
        id: []const u8,
        result: anytype,
    ) !void {
        try self.send(stream, .{
            .protocol = "cmux.protocol/2",
            .type = "response",
            .id = id,
            .ok = true,
            .result = result,
        });
    }

    fn send(
        self: *FakeServer,
        stream: std.net.Stream,
        value: anytype,
    ) !void {
        const encoded = try std.json.Stringify.valueAlloc(
            self.allocator,
            value,
            .{},
        );
        defer self.allocator.free(encoded);
        try stream.writeAll(encoded);
        try stream.writeAll("\n");
    }
};

test "session supervisor recovers create and run, waits for exit, and cancels events" {
    var fixture = try Fixture.init(.lifecycle);
    defer fixture.deinit();
    var supervisor = try fixture.connect(std.testing.allocator, 1_000);
    defer supervisor.deinit();

    const workspace = try supervisor.ensureWorkspace(
        "demo:workspace",
        .{ "demo:workspace:1", "demo:workspace:2" },
    );
    try std.testing.expect(workspace.created);
    try std.testing.expect(workspace.recovered == false);
    try std.testing.expectEqual(@as(u64, 11), workspace.revision);
    try std.testing.expectEqualStrings(
        workspace_text,
        workspace.id.slice(),
    );

    const run = try supervisor.runExact(
        &.{ "printf", "hello world" },
        "demo:run",
        .{ "demo:run:1", "demo:run:2" },
    );
    try std.testing.expect(run.recovered);
    try std.testing.expectEqual(@as(u64, 12), run.revision);
    try std.testing.expectEqualStrings(
        terminal_text,
        run.path.terminal_id.slice(),
    );

    const exit = try supervisor.waitUntilExit(
        run.path.terminal_id,
        250,
    );
    try std.testing.expectEqual(@as(u64, 13), exit.revision);
    switch (exit.outcome) {
        .exit => |status| try std.testing.expectEqual(
            @as(i32, 0),
            status,
        ),
        else => return error.ExpectedExitStatus,
    }

    const event = try supervisor.observeOneEvent();
    try std.testing.expectEqual(
        supervisor_api.EventKind.unknown,
        event.kind,
    );
    try std.testing.expectEqual(@as(u64, 1), event.sequence);
    try std.testing.expectEqual(@as(u64, 13), event.cursor_revision.?);
    try std.testing.expectEqual(
        @as(u64, 13),
        event.canceled_at_revision.?,
    );

    try fixture.join();
    try std.testing.expectEqual(
        @as(usize, 12),
        fixture.server.requests_seen,
    );
}

test "duplicate user workspace names fail before mutation" {
    var fixture = try Fixture.init(.duplicate_workspace);
    defer fixture.deinit();
    try std.testing.expectError(
        error.AmbiguousWorkspaceName,
        fixture.connect(std.testing.allocator, 1_000),
    );
    try fixture.join();
    try std.testing.expectEqual(
        @as(usize, 3),
        fixture.server.requests_seen,
    );
}

test "acknowledged session event stream survives request timeout" {
    var fixture = try Fixture.init(.delayed_event);
    defer fixture.deinit();
    const request_timeout_ms: u32 = 30;
    try std.testing.expect(delayed_event_wait_ms > request_timeout_ms);
    var supervisor = try fixture.connect(
        std.testing.allocator,
        request_timeout_ms,
    );
    defer supervisor.deinit();
    const event = try supervisor.observeOneEvent();
    try std.testing.expectEqual(
        supervisor_api.EventKind.unknown,
        event.kind,
    );
    try std.testing.expectEqual(@as(u64, 1), event.sequence);
    try std.testing.expectEqual(@as(u64, 13), event.cursor_revision.?);
    try std.testing.expectEqual(
        @as(u64, 13),
        event.canceled_at_revision.?,
    );
    try fixture.join();
    try std.testing.expectEqual(
        @as(usize, 5),
        fixture.server.requests_seen,
    );
}

test "opaque IDs reject cross-resource values" {
    try std.testing.expectError(
        error.InvalidResourceId,
        cmux.WorkspaceId.parse(session_text),
    );
    try std.testing.expectError(
        error.InvalidResourceId,
        cmux.TerminalId.parse("term_NOT_HEX"),
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
        timeout_ms: u32,
    ) !supervisor_api.SessionSupervisor {
        return supervisor_api.SessionSupervisor.connect(allocator, .{
            .socket_path = self.path,
            .machine_name = "local",
            .session_name = "main",
            .workspace_name = "ci",
            .timeout_ms = timeout_ms,
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

const MachineSnapshot = struct {
    id: []const u8,
    name: []const u8,
    origin: []const u8,
    status: []const u8,
    connectable: bool,
    deleted: bool,
    recoverable: bool,
};

const SessionSnapshot = struct {
    id: []const u8,
    machine_id: []const u8,
    name: []const u8,
    generation: []const u8,
    revision: []const u8,
    connected: bool,
};

const WorkspaceSnapshot = struct {
    id: []const u8,
    session_id: []const u8,
    name: []const u8,
    index: u32,
    focused: bool,
};

fn machineSnapshot() MachineSnapshot {
    return .{
        .id = machine_text,
        .name = "local",
        .origin = "local",
        .status = "running",
        .connectable = true,
        .deleted = false,
        .recoverable = false,
    };
}

fn sessionSnapshot() SessionSnapshot {
    return .{
        .id = session_text,
        .machine_id = machine_text,
        .name = "main",
        .generation = generation,
        .revision = "10",
        .connected = true,
    };
}

fn workspaceSnapshot(
    id: []const u8,
    name: []const u8,
    index: u32,
) WorkspaceSnapshot {
    return .{
        .id = id,
        .session_id = session_text,
        .name = name,
        .index = index,
        .focused = index == 0,
    };
}

fn terminalPath() struct {
    kind: []const u8,
    workspace_id: []const u8,
    screen_id: []const u8,
    pane_id: []const u8,
    tab_id: []const u8,
    terminal_id: []const u8,
} {
    return .{
        .kind = "terminal",
        .workspace_id = workspace_text,
        .screen_id = screen_text,
        .pane_id = pane_text,
        .tab_id = tab_text,
        .terminal_id = terminal_text,
    };
}

fn socketPath(
    allocator: std.mem.Allocator,
    temp: *const std.testing.TmpDir,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/session-supervisor.sock",
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
    return objectString(value.object, "id");
}

fn requestParams(value: std.json.Value) !std.json.ObjectMap {
    const raw = value.object.get("params") orelse
        return error.MissingParams;
    return switch (raw) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn objectString(
    object: std.json.ObjectMap,
    field: []const u8,
) ![]const u8 {
    const value = object.get(field) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn expectString(
    object: std.json.ObjectMap,
    field: []const u8,
    expected: []const u8,
) !void {
    const actual = try objectString(object, field);
    if (!std.mem.eql(u8, actual, expected)) {
        return error.UnexpectedValue;
    }
}

fn expectRoute(
    request: std.json.Value,
    machine: bool,
    session: bool,
    workspace: bool,
) !void {
    const params = try requestParams(request);
    if (machine) try expectString(params, "machine", machine_text);
    if (session) try expectString(params, "session", session_text);
    if (workspace) {
        try expectString(params, "workspace", workspace_text);
    }
}

fn expectMutation(
    request: std.json.Value,
    revision: u64,
    idempotency_key: []const u8,
) !void {
    try expectIdempotency(request, idempotency_key);
    const params = try requestParams(request);
    const revision_text = try objectString(params, "expected_revision");
    const actual = try std.fmt.parseInt(u64, revision_text, 10);
    if (actual != revision) return error.UnexpectedRevision;
}

fn expectIdempotency(
    request: std.json.Value,
    idempotency_key: []const u8,
) !void {
    try expectString(
        request.object,
        "idempotency_key",
        idempotency_key,
    );
}

fn expectArgv(
    params: std.json.ObjectMap,
    expected: []const []const u8,
) !void {
    const raw = params.get("argv") orelse return error.MissingArgv;
    const argv = switch (raw) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    if (argv.len != expected.len) return error.UnexpectedArgv;
    for (argv, expected) |actual, wanted| {
        if (actual != .string or
            !std.mem.eql(u8, actual.string, wanted))
        {
            return error.UnexpectedArgv;
        }
    }
}

// Protocol-10 conformance adapter for the public Zig SDK.

const std = @import("std");
const cmux = @import("cmux_tui").raw;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Object = std.json.ObjectMap;
const Array = std.json.Array;

fn requestObject(request: Value) !Object {
    return switch (request) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn stringField(request: Value, name: []const u8, fallback: []const u8) []const u8 {
    const object = requestObject(request) catch return fallback;
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .string => |text| text,
        else => fallback,
    };
}

fn uintField(request: Value, name: []const u8, fallback: u64) u64 {
    const object = requestObject(request) catch return fallback;
    const value = object.get(name) orelse return fallback;
    return switch (value) {
        .string => |text| std.fmt.parseInt(u64, text, 10) catch fallback,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch fallback,
        .integer => |number| std.math.cast(u64, number) orelse fallback,
        else => fallback,
    };
}

fn duplicateString(allocator: Allocator, value: []const u8) !Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn decimalString(allocator: Allocator, value: u64) !Value {
    return .{
        .string = try std.fmt.allocPrint(allocator, "{d}", .{value}),
    };
}

fn putString(
    object: *Object,
    allocator: Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    try object.put(name, try duplicateString(allocator, value));
}

fn options(request: Value) cmux.Options {
    const frame_limit = std.math.cast(
        usize,
        uintField(request, "max_frame_bytes", 16 * 1024 * 1024),
    ) orelse 16 * 1024 * 1024;
    const buffered_events = std.math.cast(
        usize,
        uintField(request, "max_buffered_events", 256),
    ) orelse 256;
    const timeout = std.math.cast(
        u32,
        uintField(request, "timeout_ms", 1000),
    ) orelse 1000;
    return .{
        .socket_path = stringField(request, "socket_path", ""),
        .timeout_ms = @max(timeout, 1),
        .limits = .{
            .max_frame_bytes = frame_limit,
            .max_value_bytes = frame_limit,
            .max_pre_ack_events = buffered_events,
            .max_pre_ack_bytes = frame_limit,
        },
    };
}

fn metadata(allocator: Allocator) !Value {
    var command_values = Array.init(allocator);
    for (cmux.protocol.commands) |item| {
        var command = Object.init(allocator);
        try putString(&command, allocator, "name", item.name);
        try putString(&command, allocator, "authority", item.authority);
        if (item.stream) |stream_kind| {
            try putString(&command, allocator, "stream", stream_kind);
        } else {
            try command.put("stream", .null);
        }
        try command_values.append(.{ .object = command });
    }

    var event_values = Array.init(allocator);
    for (cmux.protocol.events) |item| {
        var event = Object.init(allocator);
        try putString(&event, allocator, "name", item.name);
        var streams = Array.init(allocator);
        for (item.streams) |stream_kind| {
            try streams.append(try duplicateString(allocator, stream_kind));
        }
        try event.put("streams", .{ .array = streams });
        try event_values.append(.{ .object = event });
    }

    var result = Object.init(allocator);
    try result.put("commands", .{ .array = command_values });
    try result.put("events", .{ .array = event_values });
    return .{ .object = result };
}

fn identify(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var identity = try cmux.protocol.identify(&client, .{});
    defer identity.deinit();

    var result = Object.init(allocator);
    try putString(&result, allocator, "app", identity.value.app);
    try result.put("protocol", .{ .integer = identity.value.protocol });
    try result.put(
        "workspace_revision",
        try decimalString(allocator, identity.value.workspace_revision),
    );
    try result.put(
        "terminal_revision",
        try decimalString(allocator, identity.value.terminal_revision),
    );
    return .{ .object = result };
}

fn nullableLiteral(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var placement = try cmux.protocol.createTerminal(&client, .{
        .key = .{ .value = "workspace-key" },
    });
    defer placement.deinit();

    var result = Object.init(allocator);
    try putString(&result, allocator, "lifecycle", placement.value.lifecycle.toWire());
    return .{ .object = result };
}

fn optionalNonNullResponse(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var identity = try cmux.protocol.identify(&client, .{});
    defer identity.deinit();

    var result = Object.init(allocator);
    try result.put("present", .{
        .bool = identity.value.capabilities != null,
    });
    return .{ .object = result };
}

fn optionalNullableRequest(allocator: Allocator, request: Value) !Value {
    const presence = stringField(request, "presence", "");
    var info: cmux.protocol.SetClientInfoRequest = .{};
    if (std.mem.eql(u8, presence, "null")) {
        info.name = .null_value;
    } else if (std.mem.eql(u8, presence, "value")) {
        info.name = .{ .value = "conformance-client" };
    } else if (!std.mem.eql(u8, presence, "omitted")) {
        return error.UnknownPresence;
    }
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var updated = try cmux.protocol.setClientInfo(&client, info);
    defer updated.deinit();

    var result = Object.init(allocator);
    try putString(&result, allocator, "presence", presence);
    return .{ .object = result };
}

fn openStream(
    client: *cmux.Client,
    request: Value,
) !cmux.Stream {
    const stream_name = stringField(request, "stream", "");
    const surface = uintField(request, "surface", 7);
    if (std.mem.eql(u8, stream_name, "subscribe-coarse")) {
        return cmux.protocol.subscribe(client, .{
            .tree_events = .{ .value = .coarse },
        });
    }
    if (std.mem.eql(u8, stream_name, "subscribe-deltas")) {
        return cmux.protocol.subscribe(client, .{
            .tree_events = .{ .value = .deltas },
        });
    }
    if (std.mem.eql(u8, stream_name, "attach-byte")) {
        return cmux.protocol.attachSurface(client, .{
            .surface = surface,
            .mode = .{ .value = .bytes },
        });
    }
    if (std.mem.eql(u8, stream_name, "attach-render")) {
        return cmux.protocol.attachSurface(client, .{
            .surface = surface,
            .mode = .{ .value = .render },
        });
    }
    if (std.mem.eql(u8, stream_name, "attach-browser")) {
        return cmux.protocol.attachSurface(client, .{ .surface = surface });
    }
    return error.UnknownStream;
}

fn eventName(allocator: Allocator, event: cmux.protocol.Event) ![]const u8 {
    const tag = @tagName(event);
    const name = try allocator.dupe(u8, tag);
    for (name) |*byte| {
        if (byte.* == '_') byte.* = '-';
    }
    return name;
}

fn eventValue(
    allocator: Allocator,
    event: cmux.protocol.Event,
) !Value {
    var result = Object.init(allocator);
    switch (event) {
        .unknown => |unknown| {
            try putString(&result, allocator, "event", unknown.name);
            try result.put("unknown", .{ .bool = true });
            try result.put(
                "raw",
                try cmux.wire.cloneValue(allocator, unknown.raw),
            );
        },
        .output => |output| {
            try putString(&result, allocator, "event", output.event);
            try result.put(
                "surface",
                try decimalString(allocator, output.surface),
            );
            try putString(&result, allocator, "data", output.data);
        },
        .detached => |detached| {
            try putString(&result, allocator, "event", detached.event);
            try result.put(
                "surface",
                try decimalString(allocator, detached.surface),
            );
        },
        .browser_state => |state| {
            try putString(&result, allocator, "event", state.event);
            try result.put(
                "surface",
                try decimalString(allocator, state.surface),
            );
            try putString(&result, allocator, "status", state.status.toWire());
        },
        .overflow => |overflow| {
            try putString(&result, allocator, "event", overflow.event);
            try putString(&result, allocator, "error", overflow.@"error");
            if (overflow.scope) |scope| {
                try putString(&result, allocator, "scope", scope);
            }
            if (overflow.surface) |surface| {
                try result.put(
                    "surface",
                    try decimalString(allocator, surface),
                );
            }
        },
        else => {
            try putString(
                &result,
                allocator,
                "event",
                try eventName(allocator, event),
            );
        },
    }
    return .{ .object = result };
}

fn stream(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var events = Array.init(allocator);
    var source = try openStream(&client, request);
    defer source.deinit();
    var terminal = false;
    const count = @max(uintField(request, "events", 1), 1);
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        var decoded = (try cmux.protocol.nextEvent(&source, allocator)) orelse break;
        defer decoded.deinit();
        terminal = switch (decoded.value) {
            .overflow, .detached => true,
            else => false,
        };
        try events.append(try eventValue(allocator, decoded.value));
        if (terminal) break;
    }
    var result = Object.init(allocator);
    try result.put("events", .{ .array = events });
    try result.put("terminal", .{ .bool = terminal });
    return .{ .object = result };
}

fn requiredNullableEvent(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var source = try openStream(&client, request);
    defer source.deinit();
    var decoded = (try cmux.protocol.nextEvent(&source, allocator)) orelse
        return error.ExpectedClientChanged;
    defer decoded.deinit();

    var result = Object.init(allocator);
    switch (decoded.value) {
        .client_changed => |changed| switch (changed.name) {
            .null_value => try result.put("name", .null),
            .value => |name| try putString(&result, allocator, "name", name),
        },
        else => return error.ExpectedClientChanged,
    }
    return .{ .object = result };
}

fn optionalNonNullEvent(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var source = try openStream(&client, request);
    defer source.deinit();
    var decoded = (try cmux.protocol.nextEvent(&source, allocator)) orelse
        return error.ExpectedOutput;
    defer decoded.deinit();

    var result = Object.init(allocator);
    switch (decoded.value) {
        .output => |output| try result.put("present", .{
            .bool = output.colors != null,
        }),
        else => return error.ExpectedOutput,
    }
    return .{ .object = result };
}

const PendingRead = struct {
    stream: *cmux.Stream,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *PendingRead) void {
        if (cmux.protocol.nextEvent(
            self.stream,
            std.heap.page_allocator,
        )) |maybe_event| {
            if (maybe_event) |raw_event| {
                var event = raw_event;
                event.deinit();
            }
        } else |_| {}
        self.done.store(true, .release);
    }
};

fn closePendingStream(allocator: Allocator, request: Value) !Value {
    const client = try allocator.create(cmux.Client);
    errdefer allocator.destroy(client);
    client.* = try cmux.Client.connect(allocator, options(request));
    errdefer client.deinit();

    const source = try allocator.create(cmux.Stream);
    errdefer allocator.destroy(source);
    source.* = try openStream(client, request);
    errdefer source.deinit();

    const pending = try allocator.create(PendingRead);
    errdefer allocator.destroy(pending);
    pending.* = .{ .stream = source };
    const reader = try std.Thread.spawn(.{}, PendingRead.run, .{pending});

    std.Thread.sleep(uintField(request, "close_after_ms", 50) * std.time.ns_per_ms);
    source.close();
    const deadline = std.time.nanoTimestamp() +
        @as(i128, @intCast(uintField(request, "deadline_ms", 1000))) *
            std.time.ns_per_ms;
    while (!pending.done.load(.acquire) and std.time.nanoTimestamp() < deadline) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    const unblocked = pending.done.load(.acquire);
    if (unblocked) {
        reader.join();
        source.deinit();
        allocator.destroy(source);
        client.deinit();
        allocator.destroy(client);
        allocator.destroy(pending);
    } else {
        // The process exits after reporting failure. Keep thread-owned state alive.
        reader.detach();
    }

    var result = Object.init(allocator);
    try result.put("unblocked", .{ .bool = unblocked });
    return .{ .object = result };
}

fn authority(allocator: Allocator, request: Value) !Value {
    const name = stringField(request, "authority", "");
    var client_options = options(request);
    if (std.mem.eql(u8, name, "provider-authority")) {
        client_options.authority_policy = .provider_authority;
    }
    var client = try cmux.Client.connect(allocator, client_options);
    defer client.deinit();
    const command: []const u8 = if (std.mem.eql(u8, name, "control")) blk: {
        var result = try cmux.protocol.ping(&client, .{});
        result.deinit();
        break :blk "ping";
    } else if (std.mem.eql(u8, name, "frontend")) blk: {
        var result = try cmux.protocol.browserBack(&client, .{ .surface = 7 });
        result.deinit();
        break :blk "browser-back";
    } else if (std.mem.eql(u8, name, "local-admin")) blk: {
        var result = try cmux.protocol.pairingResponse(
            &client,
            .{ .approve = false, .request = 1 },
        );
        result.deinit();
        break :blk "pairing-response";
    } else if (std.mem.eql(u8, name, "provider-authority")) blk: {
        var result = try cmux.protocol.markWorkspacesProviderManaged(
            &client,
            .{ .authority = "conformance-authority" },
        );
        result.deinit();
        break :blk "mark-workspaces-provider-managed";
    } else return error.UnknownAuthority;

    var value = Object.init(allocator);
    try putString(&value, allocator, "command", command);
    return .{ .object = value };
}

fn authorityDenied(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var result = cmux.protocol.markWorkspacesProviderManaged(
        &client,
        .{ .authority = "conformance-authority" },
    ) catch |failure| {
        if (failure != error.ProviderAuthorityDenied) return failure;
        var value = Object.init(allocator);
        try value.put("denied", .{ .bool = true });
        return .{ .object = value };
    };
    result.deinit();
    return error.ExpectedAuthorityDenial;
}

const SurfaceContext = struct {
    workspace: u64,
    terminal_created: bool,
};

fn findSurface(tree: cmux.protocol.Tree, surface: u64) ?SurfaceContext {
    for (tree.workspaces) |workspace| {
        for (workspace.screens) |screen| {
            for (screen.panes) |pane| {
                switch (pane) {
                    .live => |live| {
                        for (live.tabs) |tab| {
                            if (tab.surface == surface) {
                                return .{
                                    .workspace = workspace.id,
                                    .terminal_created = tab.kind == .pty and !tab.dead,
                                };
                            }
                        }
                    },
                    .dead => {},
                }
            }
        }
    }
    return null;
}

fn workspaceNamed(tree: cmux.protocol.Tree, workspace: u64, name: []const u8) bool {
    for (tree.workspaces) |item| {
        if (item.id == workspace and std.mem.eql(u8, item.name, name)) return true;
    }
    return false;
}

fn hasWorkspace(tree: cmux.protocol.Tree, workspace: u64) bool {
    for (tree.workspaces) |item| {
        if (item.id == workspace) return true;
    }
    return false;
}

fn realFlow(allocator: Allocator, request: Value) !Value {
    var client = try cmux.Client.connect(allocator, options(request));
    defer client.deinit();
    var identity = try cmux.protocol.identify(&client, .{});
    defer identity.deinit();

    // A streaming Zig client owns its connection, so mutations use a second client.
    var event_client = try cmux.Client.connect(allocator, options(request));
    defer event_client.deinit();
    var source = try cmux.protocol.subscribe(&event_client, .{
        .tree_events = .{ .value = .deltas },
    });
    defer source.deinit();

    const marker = stringField(request, "marker", "cmux-sdk-conformance-marker");
    const workspace_name = stringField(
        request,
        "workspace_name",
        "sdk-conformance-workspace",
    );
    const renamed_name = stringField(
        request,
        "renamed_name",
        "sdk-conformance-renamed",
    );
    var created = try cmux.protocol.newWorkspace(&client, .{
        .name = .{ .value = workspace_name },
        .cols = .{ .value = 80 },
        .rows = .{ .value = 24 },
    });
    defer created.deinit();
    const surface = created.value.surface;

    const command = try std.fmt.allocPrint(allocator, "printf '{s}\\n'\r", .{marker});
    var sent = try cmux.protocol.send(&client, .{
        .surface = surface,
        .text = .{ .value = command },
    });
    defer sent.deinit();
    var waited = try cmux.protocol.waitFor(&client, .{
        .pattern = marker,
        .surface = surface,
        .timeout_ms = 5_000,
    });
    defer waited.deinit();
    var screen = try cmux.protocol.readScreen(&client, .{ .surface = surface });
    defer screen.deinit();

    var tree = try cmux.protocol.listWorkspaces(&client, .{});
    defer tree.deinit();
    const context = findSurface(tree.value, surface) orelse return error.SurfaceMissing;
    const workspace = context.workspace;

    var renamed_result = try cmux.protocol.renameWorkspace(&client, .{
        .name = renamed_name,
        .workspace = .{ .value = workspace },
    });
    defer renamed_result.deinit();
    var renamed_tree = try cmux.protocol.listWorkspaces(&client, .{});
    defer renamed_tree.deinit();
    const renamed = renamed_result.value.workspace == workspace and
        workspaceNamed(renamed_tree.value, workspace, renamed_name);

    var closed_result = try cmux.protocol.closeWorkspace(&client, .{
        .workspace = .{ .value = workspace },
    });
    defer closed_result.deinit();
    var remaining = try cmux.protocol.listWorkspaces(&client, .{});
    defer remaining.deinit();
    const disappeared = !hasWorkspace(remaining.value, workspace);

    var observed = Array.init(allocator);
    var added_index: ?usize = null;
    var renamed_index: ?usize = null;
    var closed_index: ?usize = null;
    while (observed.items.len < 64 and
        (added_index == null or renamed_index == null or closed_index == null))
    {
        var decoded = (try cmux.protocol.nextEvent(&source, allocator)) orelse
            return error.StreamClosed;
        defer decoded.deinit();
        const index = observed.items.len;
        switch (decoded.value) {
            .workspace_added => if (added_index == null) {
                added_index = index;
            },
            .workspace_renamed => if (renamed_index == null) {
                renamed_index = index;
            },
            .workspace_closed => if (closed_index == null) {
                closed_index = index;
            },
            else => {},
        }
        try observed.append(try duplicateString(
            allocator,
            try eventName(allocator, decoded.value),
        ));
    }
    const stream_ordered = added_index != null and
        renamed_index != null and
        closed_index != null and
        added_index.? < renamed_index.? and
        renamed_index.? < closed_index.?;

    var result = Object.init(allocator);
    try result.put("identified", .{ .bool = identity.value.protocol == 12 });
    try result.put("workspace_created", .{ .bool = workspace > 0 });
    try result.put("terminal_created", .{ .bool = context.terminal_created });
    try result.put("marker_sent", .{ .bool = true });
    try result.put("wait_matched", .{ .bool = waited.value.matched });
    try result.put("read_contains_marker", .{
        .bool = std.mem.indexOf(u8, screen.value.text, marker) != null,
    });
    try result.put("stream_ordered", .{ .bool = stream_ordered });
    try result.put("renamed", .{ .bool = renamed });
    try result.put("closed", .{
        .bool = closed_result.value.workspace == workspace,
    });
    try result.put("disappeared", .{ .bool = disappeared });
    try result.put("observed_events", .{ .array = observed });
    return .{ .object = result };
}

fn dispatch(allocator: Allocator, request: Value) !Value {
    const operation = stringField(request, "op", "");
    if (std.mem.eql(u8, operation, "metadata")) return metadata(allocator);
    if (std.mem.eql(u8, operation, "identify")) return identify(allocator, request);
    if (std.mem.eql(u8, operation, "nullable-literal")) {
        return nullableLiteral(allocator, request);
    }
    if (std.mem.eql(u8, operation, "optional-non-null-response")) {
        return optionalNonNullResponse(allocator, request);
    }
    if (std.mem.eql(u8, operation, "optional-nullable-request")) {
        return optionalNullableRequest(allocator, request);
    }
    if (std.mem.eql(u8, operation, "stream")) return stream(allocator, request);
    if (std.mem.eql(u8, operation, "required-nullable-event")) {
        return requiredNullableEvent(allocator, request);
    }
    if (std.mem.eql(u8, operation, "optional-non-null-event")) {
        return optionalNonNullEvent(allocator, request);
    }
    if (std.mem.eql(u8, operation, "close-pending-stream")) {
        return closePendingStream(allocator, request);
    }
    if (std.mem.eql(u8, operation, "authority")) return authority(allocator, request);
    if (std.mem.eql(u8, operation, "authority-denied")) {
        return authorityDenied(allocator, request);
    }
    if (std.mem.eql(u8, operation, "real-flow")) return realFlow(allocator, request);
    return error.UnknownOperation;
}

fn classify(failure: anyerror) []const u8 {
    const name = @errorName(failure);
    if (std.mem.indexOf(u8, name, "Timeout") != null) return "timeout";
    if (std.mem.indexOf(u8, name, "TooLarge") != null or
        std.mem.indexOf(u8, name, "Overflow") != null or
        std.mem.indexOf(u8, name, "Limit") != null)
    {
        return "limit";
    }
    if (std.mem.indexOf(u8, name, "Utf8") != null or
        std.mem.indexOf(u8, name, "Json") != null or
        std.mem.indexOf(u8, name, "Syntax") != null or
        std.mem.indexOf(u8, name, "Expected") != null or
        std.mem.indexOf(u8, name, "Unexpected") != null or
        std.mem.indexOf(u8, name, "Invalid") != null or
        std.mem.indexOf(u8, name, "Missing") != null)
    {
        return "decode";
    }
    if (std.mem.eql(u8, name, "RemoteError")) return "command";
    return "transport";
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(
        allocator,
        1024 * 1024,
    );
    defer allocator.free(input);
    var request = try cmux.wire.parse(allocator, std.mem.trim(u8, input, " \r\n"), .{
        .max_frame_bytes = 1024 * 1024,
    });
    defer request.deinit();

    var output_arena = std.heap.ArenaAllocator.init(allocator);
    defer output_arena.deinit();
    const output_allocator = output_arena.allocator();
    var response = Object.init(output_allocator);
    try response.put("contract_version", .{ .integer = 1 });
    const object = try requestObject(request.value);
    if (object.get("id")) |id| {
        try response.put(
            "id",
            try cmux.wire.cloneValue(output_allocator, id),
        );
    } else {
        try response.put("id", .null);
    }

    const value = dispatch(output_allocator, request.value) catch |failure| {
        try response.put("ok", .{ .bool = false });
        var error_value = Object.init(output_allocator);
        try putString(
            &error_value,
            output_allocator,
            "kind",
            classify(failure),
        );
        try putString(
            &error_value,
            output_allocator,
            "message",
            @errorName(failure),
        );
        try response.put("error", .{ .object = error_value });
        const encoded_failure = try cmux.wire.stringifyAlloc(
            allocator,
            .{ .object = response },
        );
        defer allocator.free(encoded_failure);
        try std.fs.File.stdout().writeAll(encoded_failure);
        try std.fs.File.stdout().writeAll("\n");
        return;
    };
    try response.put("ok", .{ .bool = true });
    try response.put("value", value);
    const encoded = try cmux.wire.stringifyAlloc(
        allocator,
        .{ .object = response },
    );
    defer allocator.free(encoded);
    try std.fs.File.stdout().writeAll(encoded);
    try std.fs.File.stdout().writeAll("\n");
}

const std = @import("std");
const cmux = @import("cmux_tui");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Object = std.json.ObjectMap;
const Array = std.json.Array;

fn asObject(value: Value) !Object {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn field(value: Value, name: []const u8) !Value {
    return (try asObject(value)).get(name) orelse error.MissingField;
}

fn stringField(value: Value, name: []const u8) ![]const u8 {
    return switch (try field(value, name)) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn integerField(value: Value, name: []const u8) !i64 {
    return switch (try field(value, name)) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch
            return error.ExpectedInteger,
        else => error.ExpectedInteger,
    };
}

test "integer fields accept numbers preserved by the lossless parser" {
    var object = Object.init(std.testing.allocator);
    defer object.deinit();
    try object.put("value", .{ .number_string = "17" });

    try std.testing.expectEqual(
        @as(i64, 17),
        try integerField(.{ .object = object }, "value"),
    );
}

fn decimalField(value: Value, name: []const u8) !u64 {
    return std.fmt.parseInt(
        u64,
        try stringField(value, name),
        10,
    );
}

fn optionalStringField(value: Value, name: []const u8) ?[]const u8 {
    const object = asObject(value) catch return null;
    const item = object.get(name) orelse return null;
    return switch (item) {
        .string => |text| text,
        else => null,
    };
}

fn arrayField(value: Value, name: []const u8) !Array {
    return switch (try field(value, name)) {
        .array => |items| items,
        else => error.ExpectedArray,
    };
}

fn putString(
    object: *Object,
    allocator: Allocator,
    name: []const u8,
    value: []const u8,
) !void {
    try object.put(name, .{ .string = try allocator.dupe(u8, value) });
}

fn decimal(allocator: Allocator, value: u64) !Value {
    return .{
        .string = try std.fmt.allocPrint(allocator, "{d}", .{value}),
    };
}

fn cloneValue(allocator: Allocator, value: Value) !Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{
            .number_string = try allocator.dupe(u8, item),
        },
        .string => |item| .{ .string = try allocator.dupe(u8, item) },
        .array => |items| blk: {
            var result = Array.init(allocator);
            for (items.items) |item| {
                try result.append(try cloneValue(allocator, item));
            }
            break :blk .{ .array = result };
        },
        .object => |source| blk: {
            var result = Object.init(allocator);
            var iterator = source.iterator();
            while (iterator.next()) |entry| {
                try result.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = result };
        },
    };
}

fn constants(request: Value) !Value {
    return field(request, "constants");
}

fn session(
    client: *cmux.Client,
    request: Value,
) !cmux.Session {
    const id = try cmux.SessionId.parse(
        try stringField(try constants(request), "session"),
    );
    return client.session(id);
}

fn workspace(
    scoped_session: cmux.Session,
    request: Value,
) !cmux.Workspace {
    const id = try cmux.WorkspaceId.parse(
        try stringField(try constants(request), "workspace"),
    );
    return scoped_session.workspace(id);
}

fn mutationOptions(request: Value) !cmux.MutationOptions {
    const values = try constants(request);
    const revision = try std.fmt.parseInt(
        u64,
        try stringField(values, "revision"),
        10,
    );
    return (try cmux.MutationOptions.withKey(
        try stringField(values, "idempotency_key"),
    )).expecting(revision);
}

fn clientOptions(request: Value) cmux.Options {
    return .{
        .socket_path = optionalStringField(request, "socket_path"),
        .timeout_ms = 15_000,
    };
}

fn ping(
    allocator: Allocator,
    scoped_session: cmux.Session,
) !Value {
    var result = try scoped_session.ping();
    defer result.deinit();
    var output = Object.init(allocator);
    try output.put("alive", .{ .bool = result.value.alive });
    try output.put(
        "cursor",
        try cursorValue(allocator, result.value.cursor),
    );
    return .{ .object = output };
}

fn mutationValue(
    allocator: Allocator,
    result: *const cmux.WorkspaceMutationResult,
) !Value {
    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "workspace_id",
        result.value.id.slice(),
    );
    try putString(
        &output,
        allocator,
        "name",
        result.value.name,
    );
    try putString(
        &output,
        allocator,
        "generation",
        result.generation,
    );
    try output.put("revision", try decimal(allocator, result.revision));
    try output.put("replayed", .{ .bool = result.replayed });
    return .{ .object = output };
}

fn resourceErrorDetailsValue(
    allocator: Allocator,
    details: cmux.ResourceErrorDetails,
) !Value {
    var output = Object.init(allocator);
    switch (details) {
        .mutation_indeterminate => |value| {
            try putString(
                &output,
                allocator,
                "idempotency_key",
                value.idempotency_key,
            );
            try putString(
                &output,
                allocator,
                "operation",
                value.operation,
            );
            try putString(
                &output,
                allocator,
                "recovery",
                value.recovery.wireName(),
            );
        },
        .revision_conflict => |value| {
            try output.put(
                "expected",
                try decimal(allocator, value.expected),
            );
            try output.put(
                "actual",
                try decimal(allocator, value.actual),
            );
        },
        .creation_conflict => |value| {
            try putString(
                &output,
                allocator,
                "correlation_key",
                value.correlation_key,
            );
            try putString(
                &output,
                allocator,
                "existing_operation",
                value.existing_operation,
            );
            try putString(
                &output,
                allocator,
                "requested_operation",
                value.requested_operation,
            );
            try putString(
                &output,
                allocator,
                "existing_fingerprint",
                value.existing_fingerprint,
            );
            try putString(
                &output,
                allocator,
                "requested_fingerprint",
                value.requested_fingerprint,
            );
        },
        .selector_ambiguous => |value| {
            if (value.scope) |scope| {
                try putString(
                    &output,
                    allocator,
                    "scope",
                    scope.wireName(),
                );
            }
            if (value.selector) |selector| {
                try putString(
                    &output,
                    allocator,
                    "selector",
                    selector,
                );
            }
            var candidates = Array.init(allocator);
            for (value.candidates) |candidate| {
                try candidates.append(.{
                    .string = try allocator.dupe(
                        u8,
                        candidate.slice(),
                    ),
                });
            }
            try output.put("candidates", .{ .array = candidates });
        },
        .unknown => |value| return cloneValue(allocator, value.raw),
        .malformed => |value| return cloneValue(allocator, value.raw),
        else => return error.UnsupportedConformanceErrorDetails,
    }
    return .{ .object = output };
}

fn mutationReplay(
    allocator: Allocator,
    scoped_workspace: cmux.Workspace,
    request: Value,
) !Value {
    const values = try constants(request);
    const name = try stringField(values, "name");
    const options = try mutationOptions(request);
    var first = try scoped_workspace.rename(name, options);
    defer first.deinit();
    var second = try scoped_workspace.rename(name, options);
    defer second.deinit();
    var output = Object.init(allocator);
    try output.put("first", try mutationValue(allocator, &first));
    try output.put("second", try mutationValue(allocator, &second));
    return .{ .object = output };
}

fn mutationError(
    allocator: Allocator,
    client: *cmux.Client,
    scoped_workspace: cmux.Workspace,
    request: Value,
) !Value {
    const values = try constants(request);
    var unexpected = scoped_workspace.rename(
        try stringField(values, "name"),
        try mutationOptions(request),
    ) catch |failure| {
        if (failure != error.RemoteError) return failure;
        const remote = client.lastResourceError() orelse
            return error.MissingResourceError;
        var output = Object.init(allocator);
        try putString(&output, allocator, "code", remote.code);
        try putString(&output, allocator, "message", remote.message);
        try output.put(
            "details",
            try resourceErrorDetailsValue(allocator, remote.details),
        );
        try output.put("retryable", .{ .bool = remote.retryable });
        return .{ .object = output };
    };
    unexpected.deinit();
    return error.MutationUnexpectedlySucceeded;
}

fn resourceErrorValue(
    allocator: Allocator,
    remote: *const cmux.ResourceError,
) !Value {
    var output = Object.init(allocator);
    try putString(&output, allocator, "code", remote.code);
    try putString(&output, allocator, "message", remote.message);
    try output.put(
        "details",
        try resourceErrorDetailsValue(allocator, remote.details),
    );
    try output.put("retryable", .{ .bool = remote.retryable });
    return .{ .object = output };
}

fn cursorValue(
    allocator: Allocator,
    cursor: ?cmux.Cursor,
) !Value {
    const value = cursor orelse return .null;
    var output = Object.init(allocator);
    try putString(&output, allocator, "generation", value.generation);
    try output.put("revision", try decimal(allocator, value.revision));
    return .{ .object = output };
}

fn putTerminalPathFields(
    output: *Object,
    allocator: Allocator,
    path: cmux.CreatedTerminalPath,
) !void {
    try putString(
        output,
        allocator,
        "workspace_id",
        path.workspace_id.slice(),
    );
    try putString(
        output,
        allocator,
        "screen_id",
        path.screen_id.slice(),
    );
    try putString(
        output,
        allocator,
        "pane_id",
        path.pane_id.slice(),
    );
    try putString(
        output,
        allocator,
        "tab_id",
        path.tab_id.slice(),
    );
    try putString(
        output,
        allocator,
        "terminal_id",
        path.terminal_id.slice(),
    );
}

fn createdTerminalPathValue(
    allocator: Allocator,
    path: cmux.CreatedTerminalPath,
) !Value {
    var output = Object.init(allocator);
    try putString(&output, allocator, "kind", "terminal");
    try putTerminalPathFields(&output, allocator, path);
    return .{ .object = output };
}

fn createdPathValue(
    allocator: Allocator,
    path: cmux.CreatedPath,
) !Value {
    var output = Object.init(allocator);
    switch (path) {
        .workspace => |value| {
            try putString(&output, allocator, "kind", "workspace");
            try putString(
                &output,
                allocator,
                "workspace_id",
                value.workspace_id.slice(),
            );
        },
        .terminal => |value| {
            try putString(&output, allocator, "kind", "terminal");
            try putTerminalPathFields(&output, allocator, value);
        },
        .browser => |value| {
            try putString(&output, allocator, "kind", "browser");
            try putString(
                &output,
                allocator,
                "workspace_id",
                value.workspace_id.slice(),
            );
            try putString(
                &output,
                allocator,
                "screen_id",
                value.screen_id.slice(),
            );
            try putString(
                &output,
                allocator,
                "pane_id",
                value.pane_id.slice(),
            );
            try putString(
                &output,
                allocator,
                "tab_id",
                value.tab_id.slice(),
            );
            try putString(
                &output,
                allocator,
                "browser_id",
                value.browser_id.slice(),
            );
        },
    }
    return .{ .object = output };
}

fn creationResolutionValue(
    allocator: Allocator,
    resolution: *const cmux.CreationResolution,
) !Value {
    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "correlation_key",
        resolution.correlation_key,
    );
    try putString(
        &output,
        allocator,
        "state",
        resolution.state.wireName(),
    );
    try putString(
        &output,
        allocator,
        "recovery",
        resolution.recovery.wireName(),
    );
    if (resolution.operation) |operation| {
        try putString(&output, allocator, "operation", operation);
    }
    if (resolution.idempotency_key) |idempotency_key| {
        try putString(
            &output,
            allocator,
            "idempotency_key",
            idempotency_key,
        );
    }
    if (resolution.created_path) |path| {
        try output.put(
            "created_path",
            try createdPathValue(allocator, path),
        );
    }
    if (resolution.generation) |generation| {
        try putString(&output, allocator, "generation", generation);
    }
    if (resolution.revision) |revision| {
        try output.put("revision", try decimal(allocator, revision));
    }
    return .{ .object = output };
}

fn exitOutcomeValue(
    allocator: Allocator,
    outcome: cmux.TerminalExitOutcome,
) !Value {
    var output = Object.init(allocator);
    switch (outcome) {
        .exit => |code| {
            try putString(&output, allocator, "kind", "exit");
            try output.put("code", .{ .integer = code });
        },
        .signal => |value| {
            try putString(&output, allocator, "kind", "signal");
            try output.put(
                "signal",
                .{ .integer = value.signal },
            );
            try output.put(
                "core_dumped",
                .{ .bool = value.core_dumped },
            );
        },
        .unknown => |reason| {
            try putString(&output, allocator, "kind", "unknown");
            try putString(&output, allocator, "reason", reason);
        },
    }
    return .{ .object = output };
}

fn terminalWaitExitValue(
    allocator: Allocator,
    result: cmux.TerminalWaitExitResult,
) !Value {
    var output = Object.init(allocator);
    switch (result) {
        .pending => |value| {
            try putString(&output, allocator, "state", "pending");
            try putString(
                &output,
                allocator,
                "terminal_id",
                value.terminal_id.slice(),
            );
            try putString(
                &output,
                allocator,
                "lifecycle",
                value.lifecycle.wireName(),
            );
            try output.put(
                "revision",
                try decimal(allocator, value.revision),
            );
        },
        .exited => |value| {
            try putString(&output, allocator, "state", "exited");
            try putString(
                &output,
                allocator,
                "terminal_id",
                value.terminal_id.slice(),
            );
            try putString(&output, allocator, "lifecycle", "exited");
            try output.put(
                "outcome",
                try exitOutcomeValue(allocator, value.outcome),
            );
            try output.put(
                "exited_at",
                try decimal(allocator, value.exited_at),
            );
            try output.put(
                "revision",
                try decimal(allocator, value.revision),
            );
        },
    }
    return .{ .object = output };
}

fn creationResolve(
    allocator: Allocator,
    scoped_session: cmux.Session,
    request: Value,
) !Value {
    var result = try scoped_session.resolveCreation(
        try stringField(try constants(request), "correlation_key"),
    );
    defer result.deinit();
    return creationResolutionValue(allocator, &result.value);
}

fn creationConflict(
    allocator: Allocator,
    client: *cmux.Client,
    scoped_session: cmux.Session,
    request: Value,
) !Value {
    const values = try constants(request);
    var unexpected = scoped_session.createWorkspace(
        .{
            .name = try stringField(values, "name"),
            .initial_content = .empty,
            .correlation_key = try stringField(
                values,
                "correlation_key",
            ),
        },
        try cmux.MutationOptions.withKey(
            try stringField(values, "idempotency_key"),
        ),
    ) catch |failure| {
        if (failure != error.RemoteError) return failure;
        var remote = client.takeResourceError() orelse
            return error.MissingResourceError;
        defer remote.deinit();
        return resourceErrorValue(allocator, &remote.value);
    };
    unexpected.deinit();
    return error.CreationConflictUnexpectedlySucceeded;
}

fn terminalWaitExit(
    allocator: Allocator,
    scoped_session: cmux.Session,
    request: Value,
) !Value {
    const terminal_id = try cmux.TerminalId.parse(
        try stringField(try constants(request), "terminal"),
    );
    var result = try scoped_session.terminal(terminal_id).waitForExit(
        try decimalField(request, "timeout_ms"),
    );
    defer result.deinit();
    return terminalWaitExitValue(allocator, result.value);
}

fn endName(reason: cmux.StreamEndReason) []const u8 {
    return switch (reason) {
        .completed => "completed",
        .canceled => "canceled",
        .closed => "closed",
        .gap => "gap",
        .@"error" => "error",
    };
}

fn streamUnknown(
    allocator: Allocator,
    scoped_session: cmux.Session,
) !Value {
    var stream = try scoped_session.events();
    defer stream.deinit();
    var item = (try stream.next()) orelse return error.StreamEndedBeforeItem;
    defer item.deinit();
    const unknown = switch (item.value) {
        .unknown => |value| value,
        else => return error.ExpectedUnknownSessionEvent,
    };
    if ((try stream.next()) != null) return error.UnexpectedSecondItem;
    const terminal = stream.end() orelse return error.MissingStreamEnd;
    var output = Object.init(allocator);
    try output.put("sequence", try decimal(allocator, item.sequence));
    try output.put("cursor", try cursorValue(allocator, item.cursor));
    try putString(
        &output,
        allocator,
        "kind",
        unknown.discriminator,
    );
    try output.put(
        "raw",
        try cloneValue(allocator, unknown.raw_object),
    );
    try putString(
        &output,
        allocator,
        "end",
        endName(terminal.reason),
    );
    return .{ .object = output };
}

fn streamCancel(
    allocator: Allocator,
    scoped_session: cmux.Session,
) !Value {
    var stream = try scoped_session.events();
    defer stream.deinit();
    _ = try stream.cancel();
    _ = try stream.cancel();
    var items_after_cancel: u32 = 0;
    while (try stream.next()) |owned| {
        var item = owned;
        item.deinit();
        items_after_cancel += 1;
    }
    const terminal = stream.end() orelse return error.MissingStreamEnd;
    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "end",
        endName(terminal.reason),
    );
    try output.put(
        "items_after_cancel",
        .{ .integer = items_after_cancel },
    );
    try output.put("cancel_calls", .{ .integer = 2 });
    return .{ .object = output };
}

fn drainEnd(stream: *cmux.SessionEventStream) ![]const u8 {
    while (try stream.next()) |owned| {
        var item = owned;
        item.deinit();
    }
    const terminal = stream.end() orelse return error.MissingStreamEnd;
    return endName(terminal.reason);
}

fn streamOverflow(
    allocator: Allocator,
    scoped_session: cmux.Session,
) !Value {
    var first = try scoped_session.events();
    defer first.deinit();
    const first_end = try drainEnd(&first);

    var second = try scoped_session.events();
    defer second.deinit();
    var item = (try second.next()) orelse return error.StreamEndedBeforeItem;
    defer item.deinit();
    const second_kind = switch (item.value) {
        .unknown => |value| value.discriminator,
        else => return error.ExpectedUnknownSessionEvent,
    };
    if ((try second.next()) != null) return error.UnexpectedSecondItem;
    _ = second.end() orelse return error.MissingStreamEnd;

    const control = try ping(allocator, scoped_session);
    const control_object = try asObject(control);
    var output = Object.init(allocator);
    try putString(&output, allocator, "first_end", first_end);
    try putString(&output, allocator, "second_kind", second_kind);
    try output.put(
        "control_alive",
        try cloneValue(
            allocator,
            control_object.get("alive") orelse return error.MissingField,
        ),
    );
    return .{ .object = output };
}

fn redaction(allocator: Allocator) !Value {
    const specifier_text = "provider://conformance-secret";
    const renderer_token = "renderer-conformance-secret";
    const specifier = cmux.SensitiveString{ .bytes = specifier_text };
    const terminal_id = try cmux.TerminalId.parse(
        "term_66666666666666666666666666666666",
    );
    const grant = try cmux.RendererGrant.init(allocator, .{
        .endpoint = "unix:///tmp/renderer",
        .terminal_id = terminal_id,
        .token = .{ .bytes = renderer_token },
        .rights = &.{"render"},
        .ttl_ms = 1000,
    });
    defer grant.deinit();
    const specifier_rendered = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{specifier},
    );
    const grant_rendered = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{grant},
    );
    var output = Object.init(allocator);
    try output.put("specifier_redacted", .{
        .bool = std.mem.indexOf(
            u8,
            specifier_rendered,
            specifier_text,
        ) == null,
    });
    try output.put("renderer_token_redacted", .{
        .bool = std.mem.indexOf(
            u8,
            grant_rendered,
            renderer_token,
        ) == null,
    });
    return .{ .object = output };
}

fn containsWorkspace(
    workspaces: []const cmux.WorkspaceSnapshot,
    id: cmux.WorkspaceId,
) bool {
    for (workspaces) |candidate| {
        if (std.mem.eql(u8, candidate.id.slice(), id.slice())) return true;
    }
    return false;
}

fn workspaceHasName(
    workspaces: []const cmux.WorkspaceSnapshot,
    id: cmux.WorkspaceId,
    expected_name: []const u8,
) bool {
    for (workspaces) |candidate| {
        if (!std.mem.eql(u8, candidate.id.slice(), id.slice())) continue;
        return std.mem.eql(u8, candidate.name, expected_name);
    }
    return false;
}

fn createdWorkspaceId(
    result: *const cmux.CreatedPathMutationResult,
) !cmux.WorkspaceId {
    return switch (result.value) {
        .workspace => |path| path.workspace_id,
        else => error.ExpectedWorkspacePath,
    };
}

fn derivedMutationOptions(
    allocator: Allocator,
    prefix: []const u8,
    suffix: []const u8,
) !cmux.MutationOptions {
    if (prefix.len + suffix.len > 128) {
        return error.InvalidIdempotencyKey;
    }
    const key = try std.fmt.allocPrint(
        allocator,
        "{s}{s}",
        .{ prefix, suffix },
    );
    return cmux.MutationOptions.withKey(key);
}

fn candidateIdsMatch(
    details: cmux.ResourceErrorDetails,
    first: cmux.WorkspaceId,
    second: cmux.WorkspaceId,
) bool {
    const candidates = switch (details) {
        .selector_ambiguous => |value| value.candidates,
        else => return false,
    };
    if (candidates.len != 2) return false;
    var found_first = false;
    var found_second = false;
    for (candidates) |candidate| {
        const encoded = candidate.slice();
        if (std.mem.eql(u8, encoded, first.slice())) {
            if (found_first) return false;
            found_first = true;
        } else if (std.mem.eql(u8, encoded, second.slice())) {
            if (found_second) return false;
            found_second = true;
        } else {
            return false;
        }
    }
    return found_first and found_second;
}

fn workspaceIdArray(
    allocator: Allocator,
    first: cmux.WorkspaceId,
    second: cmux.WorkspaceId,
) !Value {
    var output = Array.init(allocator);
    try output.append(.{
        .string = try allocator.dupe(u8, first.slice()),
    });
    try output.append(.{
        .string = try allocator.dupe(u8, second.slice()),
    });
    return .{ .array = output };
}

fn terminalPathsEqual(
    first: cmux.CreatedTerminalPath,
    second: cmux.CreatedTerminalPath,
) bool {
    return std.mem.eql(
        u8,
        first.workspace_id.slice(),
        second.workspace_id.slice(),
    ) and std.mem.eql(
        u8,
        first.screen_id.slice(),
        second.screen_id.slice(),
    ) and std.mem.eql(
        u8,
        first.pane_id.slice(),
        second.pane_id.slice(),
    ) and std.mem.eql(
        u8,
        first.tab_id.slice(),
        second.tab_id.slice(),
    ) and std.mem.eql(
        u8,
        first.terminal_id.slice(),
        second.terminal_id.slice(),
    );
}

fn terminalPathMatchesValue(
    path: cmux.CreatedTerminalPath,
    expected: Value,
) !bool {
    const object = try asObject(expected);
    if (object.count() != 6) return false;
    return std.mem.eql(
        u8,
        try stringField(expected, "kind"),
        "terminal",
    ) and std.mem.eql(
        u8,
        try stringField(expected, "workspace_id"),
        path.workspace_id.slice(),
    ) and std.mem.eql(
        u8,
        try stringField(expected, "screen_id"),
        path.screen_id.slice(),
    ) and std.mem.eql(
        u8,
        try stringField(expected, "pane_id"),
        path.pane_id.slice(),
    ) and std.mem.eql(
        u8,
        try stringField(expected, "tab_id"),
        path.tab_id.slice(),
    ) and std.mem.eql(
        u8,
        try stringField(expected, "terminal_id"),
        path.terminal_id.slice(),
    );
}

fn requiredCreatedTerminalPath(
    resolution: *const cmux.CreationResolution,
) !cmux.CreatedTerminalPath {
    const path = resolution.created_path orelse
        return error.CreationResolutionOmittedPath;
    return switch (path) {
        .terminal => |terminal| terminal,
        else => error.ExpectedTerminalPath,
    };
}

fn liveFlow(
    allocator: Allocator,
    client: *cmux.Client,
    request: Value,
) !Value {
    const scoped_session = client.session(.current);
    const ping_value = try ping(allocator, scoped_session);
    const pinged = switch ((try asObject(ping_value)).get("alive") orelse return error.MissingField) {
        .bool => |value| value,
        else => return error.ExpectedBool,
    };
    const name = try stringField(request, "workspace_name");
    var created = try scoped_session.createWorkspace(
        .{ .name = name, .initial_content = .empty },
        try cmux.MutationOptions.withKey("live-create"),
    );
    defer created.deinit();
    const workspace_id = try createdWorkspaceId(&created);
    const scoped_workspace = scoped_session.workspace(workspace_id);
    const renamed_name = try std.fmt.allocPrint(
        allocator,
        "{s}-renamed",
        .{name},
    );
    var renamed = try scoped_workspace.rename(
        renamed_name,
        try cmux.MutationOptions.withKey("live-rename"),
    );
    defer renamed.deinit();
    const renamed_ok = std.mem.eql(
        u8,
        renamed.value.name,
        renamed_name,
    );
    var listed_result = try scoped_session.listWorkspaces();
    defer listed_result.deinit();
    const listed = containsWorkspace(
        listed_result.items,
        workspace_id,
    );
    var closed = try scoped_workspace.close(
        try cmux.MutationOptions.withKey("live-close"),
    );
    defer closed.deinit();
    var remaining = try scoped_session.listWorkspaces();
    defer remaining.deinit();
    const disappeared = !containsWorkspace(
        remaining.items,
        workspace_id,
    );

    var output = Object.init(allocator);
    try output.put("pinged", .{ .bool = pinged });
    try output.put("created", .{ .bool = true });
    try output.put("renamed", .{ .bool = renamed_ok });
    try output.put("listed", .{ .bool = listed });
    try output.put("closed", .{ .bool = true });
    try output.put("disappeared", .{ .bool = disappeared });
    return .{ .object = output };
}

fn liveCreationExit(
    allocator: Allocator,
    client: *cmux.Client,
    request: Value,
) !Value {
    const scoped_session = client.session(.current);
    const stable_id = try cmux.WorkspaceId.parse(
        try stringField(request, "expected_stable_id"),
    );
    const scoped_workspace = scoped_session.workspace(stable_id);
    const key_prefix = try stringField(request, "key_prefix");

    var screen_created = try scoped_workspace.createScreen(
        .{},
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-runtime-screen",
        ),
    );
    defer screen_created.deinit();
    const screen_path = switch (screen_created.value) {
        .terminal => |path| path,
        else => return error.ScreenCreateOmittedTerminalPath,
    };
    const scoped_pane = scoped_workspace
        .screen(screen_path.screen_id)
        .pane(screen_path.pane_id);

    const correlation_key = try std.fmt.allocPrint(
        allocator,
        "{s}-terminal-correlation",
        .{key_prefix},
    );
    var run_result = try scoped_pane.run(
        .{
            .command = try cmux.RunCommand.shell(
                try stringField(request, "exit_shell"),
            ),
            .correlation_key = correlation_key,
        },
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-terminal-run",
        ),
    );
    defer run_result.deinit();
    const created_path = run_result.value;
    const scoped_terminal = scoped_session.terminal(
        created_path.terminal_id,
    );

    var pending_result = try scoped_terminal.waitForExit(
        try decimalField(request, "pending_timeout_ms"),
    );
    defer pending_result.deinit();
    const pending = switch (pending_result.value) {
        .pending => |value| value,
        .exited => return error.TerminalExitedBeforePendingObservation,
    };
    const pending_terminal_id = try allocator.dupe(
        u8,
        pending.terminal_id.slice(),
    );
    const pending_lifecycle = try allocator.dupe(
        u8,
        pending.lifecycle.wireName(),
    );

    var resolution = try scoped_session.resolveCreation(
        correlation_key,
    );
    defer resolution.deinit();
    const resolved_path = try requiredCreatedTerminalPath(
        &resolution.value,
    );
    if (!terminalPathsEqual(resolved_path, created_path)) {
        return error.CreationResolutionPathMismatch;
    }
    const creation_generation = try allocator.dupe(
        u8,
        resolution.value.generation orelse
            return error.CreationResolutionOmittedGeneration,
    );
    const creation_revision = resolution.value.revision orelse
        return error.CreationResolutionOmittedRevision;
    const creation_state = try allocator.dupe(
        u8,
        resolution.value.state.wireName(),
    );
    const creation_recovery = try allocator.dupe(
        u8,
        resolution.value.recovery.wireName(),
    );

    var exit_result = try scoped_terminal.waitForExit(
        try decimalField(request, "exit_timeout_ms"),
    );
    defer exit_result.deinit();
    const exited = switch (exit_result.value) {
        .pending => return error.TerminalRemainedPending,
        .exited => |value| value,
    };
    const exit_code = switch (exited.outcome) {
        .exit => |code| code,
        else => return error.ExpectedExitCodeOutcome,
    };
    if (@as(i64, exit_code) !=
        try integerField(request, "expected_exit_code"))
    {
        return error.UnexpectedExitCode;
    }

    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "correlation_key",
        correlation_key,
    );
    try output.put(
        "created_path",
        try createdTerminalPathValue(allocator, created_path),
    );
    try putString(
        &output,
        allocator,
        "pending_terminal_id",
        pending_terminal_id,
    );
    try putString(&output, allocator, "pending_state", "pending");
    try putString(
        &output,
        allocator,
        "pending_lifecycle",
        pending_lifecycle,
    );
    try putString(
        &output,
        allocator,
        "creation_state",
        creation_state,
    );
    try putString(
        &output,
        allocator,
        "creation_recovery",
        creation_recovery,
    );
    try putString(
        &output,
        allocator,
        "creation_generation",
        creation_generation,
    );
    try output.put(
        "creation_revision",
        try decimal(allocator, creation_revision),
    );
    try putString(&output, allocator, "exit_state", "exited");
    try putString(
        &output,
        allocator,
        "exit_terminal_id",
        exited.terminal_id.slice(),
    );
    try putString(&output, allocator, "exit_lifecycle", "exited");
    try putString(&output, allocator, "exit_kind", "exit");
    try output.put("exit_code", .{ .integer = exit_code });
    try output.put(
        "exited_at",
        try decimal(allocator, exited.exited_at),
    );
    try output.put(
        "exit_revision",
        try decimal(allocator, exited.revision),
    );
    return .{ .object = output };
}

fn liveExitRestart(
    allocator: Allocator,
    client: *cmux.Client,
    request: Value,
) !Value {
    const scoped_session = client.session(.current);
    const correlation_key = try stringField(
        request,
        "expected_correlation_key",
    );
    var resolution = try scoped_session.resolveCreation(
        correlation_key,
    );
    defer resolution.deinit();
    const resolved_path = try requiredCreatedTerminalPath(
        &resolution.value,
    );
    const expected_path = try field(request, "expected_created_path");
    if (!try terminalPathMatchesValue(resolved_path, expected_path)) {
        return error.DurableCreationPathMismatch;
    }
    if (!std.mem.eql(
        u8,
        resolution.value.correlation_key,
        correlation_key,
    )) {
        return error.DurableCorrelationKeyMismatch;
    }
    const generation = resolution.value.generation orelse
        return error.CreationResolutionOmittedGeneration;
    if (!std.mem.eql(
        u8,
        generation,
        try stringField(request, "expected_creation_generation"),
    )) {
        return error.DurableCreationGenerationMismatch;
    }
    const revision = resolution.value.revision orelse
        return error.CreationResolutionOmittedRevision;
    if (revision !=
        try decimalField(request, "expected_creation_revision"))
    {
        return error.DurableCreationRevisionMismatch;
    }

    var exit_result = try scoped_session
        .terminal(resolved_path.terminal_id)
        .waitForExit(try decimalField(request, "exit_timeout_ms"));
    defer exit_result.deinit();
    const exited = switch (exit_result.value) {
        .pending => return error.DurableTerminalExitRemainedPending,
        .exited => |value| value,
    };
    const exit_code = switch (exited.outcome) {
        .exit => |code| code,
        else => return error.ExpectedExitCodeOutcome,
    };
    if (@as(i64, exit_code) !=
        try integerField(request, "expected_exit_code"))
    {
        return error.UnexpectedExitCode;
    }
    if (exited.exited_at !=
        try decimalField(request, "expected_exited_at"))
    {
        return error.DurableExitTimestampMismatch;
    }
    if (exited.revision !=
        try decimalField(request, "expected_exit_revision"))
    {
        return error.DurableExitRevisionMismatch;
    }

    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "correlation_key",
        resolution.value.correlation_key,
    );
    try output.put(
        "created_path",
        try createdTerminalPathValue(allocator, resolved_path),
    );
    try putString(
        &output,
        allocator,
        "creation_state",
        resolution.value.state.wireName(),
    );
    try putString(
        &output,
        allocator,
        "creation_recovery",
        resolution.value.recovery.wireName(),
    );
    try putString(
        &output,
        allocator,
        "creation_generation",
        generation,
    );
    try output.put(
        "creation_revision",
        try decimal(allocator, revision),
    );
    try putString(&output, allocator, "exit_state", "exited");
    try putString(
        &output,
        allocator,
        "exit_terminal_id",
        exited.terminal_id.slice(),
    );
    try putString(&output, allocator, "exit_lifecycle", "exited");
    try putString(&output, allocator, "exit_kind", "exit");
    try output.put("exit_code", .{ .integer = exit_code });
    try output.put(
        "exited_at",
        try decimal(allocator, exited.exited_at),
    );
    try output.put(
        "exit_revision",
        try decimal(allocator, exited.revision),
    );
    return .{ .object = output };
}

fn liveSetup(
    allocator: Allocator,
    client: *cmux.Client,
    request: Value,
) !Value {
    const scoped_session = client.session(.current);
    const ping_value = try ping(allocator, scoped_session);
    const pinged = switch ((try asObject(ping_value)).get("alive") orelse return error.MissingField) {
        .bool => |value| value,
        else => return error.ExpectedBool,
    };
    const base_name = try stringField(request, "workspace_name");
    const key_prefix = try stringField(request, "key_prefix");
    const renamed_name = try std.fmt.allocPrint(
        allocator,
        "{s}-renamed",
        .{base_name},
    );
    const duplicate_name = try std.fmt.allocPrint(
        allocator,
        "{s}-duplicate",
        .{base_name},
    );
    const forbidden_name = try std.fmt.allocPrint(
        allocator,
        "{s}-must-not-apply",
        .{base_name},
    );

    var stable_created = try scoped_session.createWorkspace(
        .{ .name = base_name, .initial_content = .empty },
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-stable-create",
        ),
    );
    defer stable_created.deinit();
    const stable_id = try createdWorkspaceId(&stable_created);
    var stable_rename = try scoped_session.workspace(stable_id).rename(
        renamed_name,
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-stable-rename",
        ),
    );
    defer stable_rename.deinit();
    const stable_renamed = std.mem.eql(
        u8,
        stable_rename.value.name,
        renamed_name,
    );

    var duplicate_a = try scoped_session.createWorkspace(
        .{ .name = duplicate_name, .initial_content = .empty },
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-duplicate-a",
        ),
    );
    defer duplicate_a.deinit();
    const duplicate_a_id = try createdWorkspaceId(&duplicate_a);
    var duplicate_b = try scoped_session.createWorkspace(
        .{ .name = duplicate_name, .initial_content = .empty },
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-duplicate-b",
        ),
    );
    defer duplicate_b.deinit();
    const duplicate_b_id = try createdWorkspaceId(&duplicate_b);

    var unexpected = scoped_session.workspace(.{
        .name = duplicate_name,
    }).rename(
        forbidden_name,
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-ambiguous-rename",
        ),
    ) catch |failure| {
        if (failure != error.RemoteError) return failure;
        var ambiguity = client.takeResourceError() orelse
            return error.MissingResourceError;
        defer ambiguity.deinit();
        const ambiguity_code = try allocator.dupe(
            u8,
            ambiguity.value.code,
        );
        const preserved_candidates = std.mem.eql(
            u8,
            ambiguity.value.code,
            "selector.ambiguous",
        ) and candidateIdsMatch(
            ambiguity.value.details,
            duplicate_a_id,
            duplicate_b_id,
        );

        var listed = try scoped_session.listWorkspaces();
        defer listed.deinit();
        const no_mutation =
            workspaceHasName(
                listed.items,
                duplicate_a_id,
                duplicate_name,
            ) and
            workspaceHasName(
                listed.items,
                duplicate_b_id,
                duplicate_name,
            );

        var output = Object.init(allocator);
        try output.put("pinged", .{ .bool = pinged });
        try putString(
            &output,
            allocator,
            "stable_id",
            stable_id.slice(),
        );
        try output.put(
            "stable_renamed",
            .{ .bool = stable_renamed },
        );
        try output.put(
            "duplicate_ids",
            try workspaceIdArray(
                allocator,
                duplicate_a_id,
                duplicate_b_id,
            ),
        );
        try putString(
            &output,
            allocator,
            "ambiguity_code",
            ambiguity_code,
        );
        try output.put(
            "ambiguity_preserved_all_candidates",
            .{ .bool = preserved_candidates },
        );
        try output.put(
            "no_mutation",
            .{ .bool = no_mutation },
        );
        return .{ .object = output };
    };
    unexpected.deinit();
    return error.AmbiguousMutationUnexpectedlySucceeded;
}

fn expectedDuplicateIds(request: Value) ![2]cmux.WorkspaceId {
    const encoded = try arrayField(request, "expected_duplicate_ids");
    if (encoded.items.len != 2) return error.ExpectedTwoDuplicateIds;
    var result: [2]cmux.WorkspaceId = undefined;
    for (encoded.items, 0..) |item, index| {
        result[index] = try cmux.WorkspaceId.parse(switch (item) {
            .string => |text| text,
            else => return error.ExpectedString,
        });
    }
    return result;
}

fn liveRestart(
    allocator: Allocator,
    client: *cmux.Client,
    request: Value,
) !Value {
    const scoped_session = client.session(.current);
    const base_name = try stringField(request, "workspace_name");
    const key_prefix = try stringField(request, "key_prefix");
    const stable_id = try cmux.WorkspaceId.parse(
        try stringField(request, "expected_stable_id"),
    );
    const duplicate_ids = try expectedDuplicateIds(request);
    const stable_name = try std.fmt.allocPrint(
        allocator,
        "{s}-renamed",
        .{base_name},
    );
    const duplicate_name = try std.fmt.allocPrint(
        allocator,
        "{s}-duplicate",
        .{base_name},
    );

    var listed = try scoped_session.listWorkspaces();
    defer listed.deinit();
    const same_ids =
        containsWorkspace(listed.items, stable_id) and
        containsWorkspace(listed.items, duplicate_ids[0]) and
        containsWorkspace(listed.items, duplicate_ids[1]);
    const stable_name_preserved = workspaceHasName(
        listed.items,
        stable_id,
        stable_name,
    );
    const duplicates_preserved =
        workspaceHasName(
            listed.items,
            duplicate_ids[0],
            duplicate_name,
        ) and
        workspaceHasName(
            listed.items,
            duplicate_ids[1],
            duplicate_name,
        );

    var stable_close = try scoped_session.workspace(stable_id).close(
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-close-stable",
        ),
    );
    defer stable_close.deinit();
    var duplicate_a_close = try scoped_session.workspace(
        duplicate_ids[0],
    ).close(
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-close-a",
        ),
    );
    defer duplicate_a_close.deinit();
    var duplicate_b_close = try scoped_session.workspace(
        duplicate_ids[1],
    ).close(
        try derivedMutationOptions(
            allocator,
            key_prefix,
            "-close-b",
        ),
    );
    defer duplicate_b_close.deinit();

    var remaining = try scoped_session.listWorkspaces();
    defer remaining.deinit();
    const disappeared =
        !containsWorkspace(remaining.items, stable_id) and
        !containsWorkspace(remaining.items, duplicate_ids[0]) and
        !containsWorkspace(remaining.items, duplicate_ids[1]);

    var output = Object.init(allocator);
    try output.put("same_ids", .{ .bool = same_ids });
    try output.put(
        "stable_name_preserved",
        .{ .bool = stable_name_preserved },
    );
    try output.put(
        "duplicates_preserved",
        .{ .bool = duplicates_preserved },
    );
    try output.put("closed", .{ .bool = true });
    try output.put("disappeared", .{ .bool = disappeared });
    return .{ .object = output };
}

fn dispatch(allocator: Allocator, request: Value) !Value {
    const operation = try stringField(request, "op");
    if (std.mem.eql(u8, operation, "redaction")) {
        return redaction(allocator);
    }

    var client = try cmux.Client.connect(
        allocator,
        clientOptions(request),
    );
    defer client.deinit();
    if (std.mem.eql(u8, operation, "live-setup")) {
        return liveSetup(allocator, &client, request);
    }
    if (std.mem.eql(u8, operation, "live-creation-exit")) {
        return liveCreationExit(allocator, &client, request);
    }
    if (std.mem.eql(u8, operation, "live-exit-restart")) {
        return liveExitRestart(allocator, &client, request);
    }
    if (std.mem.eql(u8, operation, "live-restart")) {
        return liveRestart(allocator, &client, request);
    }
    if (std.mem.eql(u8, operation, "live-flow")) {
        return liveFlow(allocator, &client, request);
    }
    const scoped_session = try session(&client, request);

    if (std.mem.eql(u8, operation, "read")) {
        return ping(allocator, scoped_session);
    }
    if (std.mem.eql(u8, operation, "creation-resolve")) {
        return creationResolve(allocator, scoped_session, request);
    }
    if (std.mem.eql(u8, operation, "creation-conflict")) {
        return creationConflict(
            allocator,
            &client,
            scoped_session,
            request,
        );
    }
    if (std.mem.eql(u8, operation, "terminal-wait-exit")) {
        return terminalWaitExit(allocator, scoped_session, request);
    }

    const scoped_workspace = try workspace(scoped_session, request);
    if (std.mem.eql(u8, operation, "mutation-replay")) {
        return mutationReplay(
            allocator,
            scoped_workspace,
            request,
        );
    }
    if (std.mem.eql(u8, operation, "mutation-error")) {
        return mutationError(
            allocator,
            &client,
            scoped_workspace,
            request,
        );
    }
    if (std.mem.eql(u8, operation, "stream-unknown")) {
        return streamUnknown(allocator, scoped_session);
    }
    if (std.mem.eql(u8, operation, "stream-cancel")) {
        return streamCancel(allocator, scoped_session);
    }
    if (std.mem.eql(u8, operation, "stream-overflow")) {
        return streamOverflow(allocator, scoped_session);
    }
    return error.UnknownOperation;
}

fn writeResponse(allocator: Allocator, response: Value) !void {
    const encoded = try std.json.Stringify.valueAlloc(
        allocator,
        response,
        .{},
    );
    defer allocator.free(encoded);
    try std.fs.File.stdout().writeAll(encoded);
    try std.fs.File.stdout().writeAll("\n");
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
    var parsed = try std.json.parseFromSlice(
        Value,
        allocator,
        std.mem.trim(u8, input, " \r\n"),
        .{
            .allocate = .alloc_always,
            .parse_numbers = false,
            .duplicate_field_behavior = .@"error",
        },
    );
    defer parsed.deinit();

    var output_arena = std.heap.ArenaAllocator.init(allocator);
    defer output_arena.deinit();
    const output = output_arena.allocator();
    var response = Object.init(output);
    try response.put("contract_version", .{ .integer = 2 });
    const request_object = try asObject(parsed.value);
    try response.put(
        "id",
        if (request_object.get("id")) |id|
            try cloneValue(output, id)
        else
            .null,
    );
    const value = dispatch(output, parsed.value) catch |failure| {
        try response.put("ok", .{ .bool = false });
        var encoded_error = Object.init(output);
        try putString(&encoded_error, output, "kind", "adapter");
        try putString(
            &encoded_error,
            output,
            "message",
            @errorName(failure),
        );
        try response.put("error", .{ .object = encoded_error });
        try writeResponse(allocator, .{ .object = response });
        return;
    };
    try response.put("ok", .{ .bool = true });
    try response.put("value", value);
    try writeResponse(allocator, .{ .object = response });
}

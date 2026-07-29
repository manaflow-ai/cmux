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
    var result = try scoped_session.read(.session_ping, null);
    defer result.deinit();
    const object = try asObject(result.value);
    var output = Object.init(allocator);
    try output.put(
        "alive",
        try cloneValue(
            allocator,
            object.get("alive") orelse return error.MissingField,
        ),
    );
    try output.put(
        "cursor",
        try cloneValue(
            allocator,
            object.get("cursor") orelse return error.MissingField,
        ),
    );
    return .{ .object = output };
}

fn mutationValue(
    allocator: Allocator,
    result: *const cmux.MutationResult,
) !Value {
    const logical = try asObject(result.value);
    var output = Object.init(allocator);
    try putString(
        &output,
        allocator,
        "workspace_id",
        switch (logical.get("id") orelse return error.MissingField) {
            .string => |text| text,
            else => return error.ExpectedString,
        },
    );
    try putString(
        &output,
        allocator,
        "name",
        switch (logical.get("name") orelse return error.MissingField) {
            .string => |text| text,
            else => return error.ExpectedString,
        },
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
            if (remote.details) |details|
                try cloneValue(allocator, details)
            else
                .null,
        );
        try output.put("retryable", .{ .bool = remote.retryable });
        return .{ .object = output };
    };
    unexpected.deinit();
    return error.MutationUnexpectedlySucceeded;
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

fn workspaceItems(value: Value) !Array {
    return switch (value) {
        .array => |items| items,
        .object => |object| switch (object.get("workspaces") orelse
            return error.MissingField) {
            .array => |items| items,
            else => return error.ExpectedArray,
        },
        else => error.ExpectedArray,
    };
}

fn containsWorkspace(value: Value, id: cmux.WorkspaceId) !bool {
    const workspaces = try workspaceItems(value);
    for (workspaces.items) |candidate_value| {
        const candidate = try asObject(candidate_value);
        const encoded = switch (candidate.get("id") orelse continue) {
            .string => |text| text,
            else => continue,
        };
        if (std.mem.eql(u8, encoded, id.slice())) return true;
    }
    return false;
}

fn workspaceHasName(
    value: Value,
    id: cmux.WorkspaceId,
    expected_name: []const u8,
) !bool {
    const workspaces = try workspaceItems(value);
    for (workspaces.items) |candidate_value| {
        const candidate = try asObject(candidate_value);
        const encoded_id = switch (candidate.get("id") orelse continue) {
            .string => |text| text,
            else => continue,
        };
        if (!std.mem.eql(u8, encoded_id, id.slice())) continue;
        const encoded_name = switch (candidate.get("name") orelse return false) {
            .string => |text| text,
            else => return false,
        };
        return std.mem.eql(u8, encoded_name, expected_name);
    }
    return false;
}

fn createdWorkspaceId(result: *const cmux.MutationResult) !cmux.WorkspaceId {
    const created_path = (try result.createdPath()) orelse
        return error.MissingCreatedPath;
    return switch (created_path) {
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
    details: ?Value,
    first: cmux.WorkspaceId,
    second: cmux.WorkspaceId,
) !bool {
    const value = details orelse return false;
    const candidates = try arrayField(value, "candidates");
    if (candidates.items.len != 2) return false;
    var found_first = false;
    var found_second = false;
    for (candidates.items) |candidate| {
        const encoded = switch (candidate) {
            .string => |text| text,
            else => return false,
        };
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
    const renamed_object = try asObject(renamed.value);
    const renamed_ok = std.mem.eql(
        u8,
        switch (renamed_object.get("name") orelse return error.MissingField) {
            .string => |text| text,
            else => return error.ExpectedString,
        },
        renamed_name,
    );
    var listed_result = try scoped_session.read(.workspace_list, null);
    defer listed_result.deinit();
    const listed = try containsWorkspace(
        listed_result.value,
        workspace_id,
    );
    var closed = try scoped_workspace.close(
        try cmux.MutationOptions.withKey("live-close"),
    );
    defer closed.deinit();
    var remaining = try scoped_session.read(.workspace_list, null);
    defer remaining.deinit();
    const disappeared = !try containsWorkspace(
        remaining.value,
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
    const renamed_object = try asObject(stable_rename.value);
    const stable_renamed = std.mem.eql(
        u8,
        switch (renamed_object.get("name") orelse return error.MissingField) {
            .string => |text| text,
            else => return error.ExpectedString,
        },
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
        ) and try candidateIdsMatch(
            ambiguity.value.details,
            duplicate_a_id,
            duplicate_b_id,
        );

        var listed = try scoped_session.read(.workspace_list, null);
        defer listed.deinit();
        const no_mutation =
            try workspaceHasName(
                listed.value,
                duplicate_a_id,
                duplicate_name,
            ) and
            try workspaceHasName(
                listed.value,
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

    var listed = try scoped_session.read(.workspace_list, null);
    defer listed.deinit();
    const same_ids =
        try containsWorkspace(listed.value, stable_id) and
        try containsWorkspace(listed.value, duplicate_ids[0]) and
        try containsWorkspace(listed.value, duplicate_ids[1]);
    const stable_name_preserved = try workspaceHasName(
        listed.value,
        stable_id,
        stable_name,
    );
    const duplicates_preserved =
        try workspaceHasName(
            listed.value,
            duplicate_ids[0],
            duplicate_name,
        ) and
        try workspaceHasName(
            listed.value,
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

    var remaining = try scoped_session.read(.workspace_list, null);
    defer remaining.deinit();
    const disappeared =
        !try containsWorkspace(remaining.value, stable_id) and
        !try containsWorkspace(remaining.value, duplicate_ids[0]) and
        !try containsWorkspace(remaining.value, duplicate_ids[1]);

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
    if (std.mem.eql(u8, operation, "live-restart")) {
        return liveRestart(allocator, &client, request);
    }
    if (std.mem.eql(u8, operation, "live-flow")) {
        return liveFlow(allocator, &client, request);
    }
    const scoped_session = try session(&client, request);
    const scoped_workspace = try workspace(scoped_session, request);

    if (std.mem.eql(u8, operation, "read")) {
        return ping(allocator, scoped_session);
    }
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

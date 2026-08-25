const std = @import("std");
const protocol = @import("generated/protocol.zig");
const wire = @import("wire.zig");

test "generated request optional non-null preserves omission and value" {
    var missing_json = try wire.parse(
        std.testing.allocator,
        "{\"surface\":7}",
        .{},
    );
    defer missing_json.deinit();
    var missing = try wire.decode(
        protocol.SendRequest,
        std.testing.allocator,
        missing_json.value,
    );
    defer missing.deinit();
    try std.testing.expect(missing.value.paste == null);

    var missing_encoded = try wire.encode(
        std.testing.allocator,
        missing.value,
    );
    defer missing_encoded.deinit();
    try std.testing.expect(
        missing_encoded.value.object.get("paste") == null,
    );

    var value_json = try wire.parse(
        std.testing.allocator,
        "{\"surface\":7,\"paste\":false}",
        .{},
    );
    defer value_json.deinit();
    var value = try wire.decode(
        protocol.SendRequest,
        std.testing.allocator,
        value_json.value,
    );
    defer value.deinit();
    try std.testing.expectEqual(false, value.value.paste.?);

    var value_encoded = try wire.encode(
        std.testing.allocator,
        value.value,
    );
    defer value_encoded.deinit();
    try std.testing.expectEqual(
        false,
        value_encoded.value.object.get("paste").?.bool,
    );

    var null_json = try wire.parse(
        std.testing.allocator,
        "{\"surface\":7,\"paste\":null}",
        .{},
    );
    defer null_json.deinit();
    try std.testing.expectError(
        error.UnexpectedNull,
        wire.decode(
            protocol.SendRequest,
            std.testing.allocator,
            null_json.value,
        ),
    );
}

test "generated result optional non-null preserves omission and value" {
    var missing_json = try wire.parse(
        std.testing.allocator,
        "{\"workspaces\":[]}",
        .{},
    );
    defer missing_json.deinit();
    var missing = try wire.decode(
        protocol.Tree,
        std.testing.allocator,
        missing_json.value,
    );
    defer missing.deinit();
    try std.testing.expect(missing.value.registry_id == null);

    var missing_encoded = try wire.encode(
        std.testing.allocator,
        missing.value,
    );
    defer missing_encoded.deinit();
    try std.testing.expect(
        missing_encoded.value.object.get("registry_id") == null,
    );

    var value_json = try wire.parse(
        std.testing.allocator,
        "{\"registry_id\":\"registry-1\",\"workspaces\":[]}",
        .{},
    );
    defer value_json.deinit();
    var value = try wire.decode(
        protocol.Tree,
        std.testing.allocator,
        value_json.value,
    );
    defer value.deinit();
    try std.testing.expectEqualStrings(
        "registry-1",
        value.value.registry_id.?,
    );

    var null_json = try wire.parse(
        std.testing.allocator,
        "{\"registry_id\":null,\"workspaces\":[]}",
        .{},
    );
    defer null_json.deinit();
    try std.testing.expectError(
        error.UnexpectedNull,
        wire.decode(
            protocol.Tree,
            std.testing.allocator,
            null_json.value,
        ),
    );
}

test "generated event optional non-null uses strict event decoding" {
    const base =
        "{\"event\":\"colors-changed\",\"bg\":null,\"fg\":null," ++
        "\"selection_bg\":null,\"selection_fg\":null";

    var missing_json = try wire.parse(
        std.testing.allocator,
        base ++ "}",
        .{},
    );
    defer missing_json.deinit();
    var missing = try protocol.decodeEvent(
        std.testing.allocator,
        missing_json.value,
    );
    defer missing.deinit();
    switch (missing.value) {
        .colors_changed => |event| {
            try std.testing.expect(event.surface == null);
        },
        else => return error.ExpectedColorsChanged,
    }

    var value_json = try wire.parse(
        std.testing.allocator,
        base ++ ",\"surface\":9}",
        .{},
    );
    defer value_json.deinit();
    var value = try protocol.decodeEvent(
        std.testing.allocator,
        value_json.value,
    );
    defer value.deinit();
    switch (value.value) {
        .colors_changed => |event| {
            try std.testing.expectEqual(@as(u64, 9), event.surface.?);
        },
        else => return error.ExpectedColorsChanged,
    }

    var null_json = try wire.parse(
        std.testing.allocator,
        base ++ ",\"surface\":null}",
        .{},
    );
    defer null_json.deinit();
    try std.testing.expectError(
        error.UnexpectedNull,
        protocol.decodeEvent(std.testing.allocator, null_json.value),
    );
}

test "optional nullable fields retain absent null and value states" {
    var missing_json = try wire.parse(
        std.testing.allocator,
        "{}",
        .{},
    );
    defer missing_json.deinit();
    var missing = try wire.decode(
        protocol.RunRequest,
        std.testing.allocator,
        missing_json.value,
    );
    defer missing.deinit();
    try std.testing.expect(missing.value.key == .absent);

    var missing_encoded = try wire.encode(
        std.testing.allocator,
        missing.value,
    );
    defer missing_encoded.deinit();
    try std.testing.expect(
        missing_encoded.value.object.get("key") == null,
    );

    var null_json = try wire.parse(
        std.testing.allocator,
        "{\"key\":null}",
        .{},
    );
    defer null_json.deinit();
    var null_value = try wire.decode(
        protocol.RunRequest,
        std.testing.allocator,
        null_json.value,
    );
    defer null_value.deinit();
    try std.testing.expect(null_value.value.key == .null_value);

    var null_encoded = try wire.encode(
        std.testing.allocator,
        null_value.value,
    );
    defer null_encoded.deinit();
    try std.testing.expect(
        null_encoded.value.object.get("key").? == .null,
    );

    var value_json = try wire.parse(
        std.testing.allocator,
        "{\"key\":\"workspace-key\"}",
        .{},
    );
    defer value_json.deinit();
    var value = try wire.decode(
        protocol.RunRequest,
        std.testing.allocator,
        value_json.value,
    );
    defer value.deinit();
    switch (value.value.key) {
        .value => |key| {
            try std.testing.expectEqualStrings("workspace-key", key);
        },
        else => return error.ExpectedValue,
    }
}

test "required nullable fields reject omission and preserve null or value" {
    var missing_json = try wire.parse(
        std.testing.allocator,
        "{\"bg\":null,\"selection_bg\":null,\"selection_fg\":null}",
        .{},
    );
    defer missing_json.deinit();
    try std.testing.expectError(
        error.MissingField,
        wire.decode(
            protocol.TerminalColors,
            std.testing.allocator,
            missing_json.value,
        ),
    );

    var null_json = try wire.parse(
        std.testing.allocator,
        "{\"bg\":null,\"fg\":null,\"selection_bg\":null," ++
            "\"selection_fg\":null}",
        .{},
    );
    defer null_json.deinit();
    var null_value = try wire.decode(
        protocol.TerminalColors,
        std.testing.allocator,
        null_json.value,
    );
    defer null_value.deinit();
    try std.testing.expect(null_value.value.fg == .null_value);

    var value_json = try wire.parse(
        std.testing.allocator,
        "{\"bg\":null,\"fg\":\"#ffffff\",\"selection_bg\":null," ++
            "\"selection_fg\":null}",
        .{},
    );
    defer value_json.deinit();
    var value = try wire.decode(
        protocol.TerminalColors,
        std.testing.allocator,
        value_json.value,
    );
    defer value.deinit();
    switch (value.value.fg) {
        .value => |fg| {
            try std.testing.expectEqualStrings("#ffffff", fg);
        },
        else => return error.ExpectedValue,
    }
}

fn identity(
    capabilities: ?[]const []const u8,
) protocol.IdentifyResult {
    return .{
        .app = "cmux-tui",
        .capabilities = capabilities,
        .daemon_handoff = 0,
        .generation = "generation-1",
        .pid = 42,
        .protocol = 10,
        .registry_id = "registry-1",
        .session = "main",
        .terminal_revision = 3,
        .version = "0.0.0-test",
        .workspace_revision = 7,
    };
}

test "schema defaults do not collapse optional non-null wire presence" {
    var omitted = try wire.encode(
        std.testing.allocator,
        identity(null),
    );
    defer omitted.deinit();
    try std.testing.expect(
        omitted.value.object.get("capabilities") == null,
    );

    const no_capabilities = [_][]const u8{};
    var present = try wire.encode(
        std.testing.allocator,
        identity(&no_capabilities),
    );
    defer present.deinit();
    const encoded = present.value.object.get("capabilities") orelse
        return error.ExpectedCapabilities;
    try std.testing.expectEqual(@as(usize, 0), encoded.array.items.len);
}

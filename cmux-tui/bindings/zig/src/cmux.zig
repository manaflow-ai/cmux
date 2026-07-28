const std = @import("std");

pub const wire = @import("wire.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");
pub const capabilities = @import("capabilities.zig");
pub const provider = @import("provider.zig");
pub const protocol = @import("generated/protocol.zig");

pub const Client = client.Client;
pub const AuthorityPolicy = client.AuthorityPolicy;
pub const CommandRequirements = client.CommandRequirements;
pub const FieldRequirement = client.FieldRequirement;
pub const UncheckedCommand = client.UncheckedCommand;
pub const OwnedRemoteError = client.OwnedRemoteError;
pub const Connection = transport.Connection;
pub const Options = client.Options;
pub const Limits = wire.Limits;
pub const Stream = client.Stream;
pub const Value = wire.Value;
pub const Field = wire.Field;
pub const Nullable = wire.Nullable;
pub const Map = wire.Map;
pub const decodeBase64Alloc = wire.decodeBase64Alloc;
pub const encodeBase64Alloc = wire.encodeBase64Alloc;
pub const eventWireName = protocol.eventWireName;
pub const hasCapability = capabilities.hasCapability;
pub const requireCapability = capabilities.requireCapability;
pub const ProviderClient = provider.ProviderClient;
pub const ProviderOptions = provider.Options;
pub const ProviderSnapshot = provider.Snapshot;
pub const ProviderWorkspace = provider.Workspace;
pub const ProviderMutation = provider.Mutation;
pub const ProviderCreateWorkspaceOptions = provider.CreateWorkspaceOptions;
pub const ProviderRenameWorkspaceOptions = provider.RenameWorkspaceOptions;
pub const ProviderCloseWorkspaceOptions = provider.CloseWorkspaceOptions;

test {
    std.testing.refAllDecls(capabilities);
    std.testing.refAllDecls(provider);
    _ = @import("authority_test.zig");
    _ = @import("provider_test.zig");
    _ = @import("stream_client_test.zig");
    _ = @import("wire_presence_test.zig");
    _ = @import("generated/presence_test.zig");
    std.testing.refAllDecls(protocol);
    try std.testing.expectEqual(@as(usize, 83), protocol.command_count);
    try std.testing.expectEqual(@as(usize, 44), protocol.event_count);
}

test "unknown generated event preserves raw JSON" {
    var parsed = try wire.parse(
        std.testing.allocator,
        "{\"event\":\"future-event\",\"id\":18446744073709551615}",
        .{},
    );
    defer parsed.deinit();
    var event = try protocol.decodeEvent(std.testing.allocator, parsed.value);
    defer event.deinit();
    try std.testing.expectEqualStrings(
        "future-event",
        protocol.eventWireName(event.value),
    );
    switch (event.value) {
        .unknown => |unknown| {
            try std.testing.expectEqualStrings("future-event", unknown.name);
            try std.testing.expectEqual(
                std.math.maxInt(u64),
                try wire.decodeLeaky(
                    u64,
                    std.testing.allocator,
                    unknown.raw.object.get("id").?,
                ),
            );
        },
        else => return error.ExpectedUnknownEvent,
    }
}

test "known event exposes its exact wire name" {
    var parsed = try wire.parse(
        std.testing.allocator,
        "{\"event\":\"empty\"}",
        .{},
    );
    defer parsed.deinit();
    var event = try protocol.decodeEvent(std.testing.allocator, parsed.value);
    defer event.deinit();
    try std.testing.expectEqualStrings(
        "empty",
        protocol.eventWireName(event.value),
    );
}

test "generated recursive layout union round trips" {
    const left = protocol.Layout{ .leaf = .{ .pane = 1 } };
    const right = protocol.Layout{ .leaf = .{ .pane = 2 } };
    const layout = protocol.Layout{ .split = .{
        .a = &left,
        .b = &right,
        .dir = .right,
        .ratio = 0.5,
    } };
    var encoded = try wire.encode(std.testing.allocator, layout);
    defer encoded.deinit();
    try std.testing.expectEqualStrings(
        "split",
        try wire.objectString(encoded.value, "type"),
    );
    var decoded = try wire.decode(
        protocol.Layout,
        std.testing.allocator,
        encoded.value,
    );
    defer decoded.deinit();
    switch (decoded.value) {
        .split => |split| {
            try std.testing.expectEqual(protocol.SplitDirection.right, split.dir);
            try std.testing.expectApproxEqAbs(@as(f32, 0.5), split.ratio, 0.001);
            try std.testing.expectEqual(@as(u64, 1), split.a.leaf.pane);
            try std.testing.expectEqual(@as(u64, 2), split.b.leaf.pane);
        },
        else => return error.ExpectedSplit,
    }
}

test "generated untagged pane and typed map decode" {
    var pane_json = try wire.parse(
        std.testing.allocator,
        "{\"id\":7,\"dead\":true}",
        .{},
    );
    defer pane_json.deinit();
    var pane = try wire.decode(
        protocol.Pane,
        std.testing.allocator,
        pane_json.value,
    );
    defer pane.deinit();
    try std.testing.expectEqual(@as(u64, 7), pane.value.dead.id);

    var colors_json = try wire.parse(
        std.testing.allocator,
        "{\"fg\":null,\"bg\":null,\"selection_bg\":null," ++
            "\"selection_fg\":null,\"palette\":{\"0\":\"#000000\",\"255\":\"#ffffff\"}}",
        .{},
    );
    defer colors_json.deinit();
    var colors = try wire.decode(
        protocol.TerminalColors,
        std.testing.allocator,
        colors_json.value,
    );
    defer colors.deinit();
    const palette = colors.value.palette orelse return error.ExpectedPalette;
    try std.testing.expectEqualStrings("#000000", palette.get("0").?);
    try std.testing.expectEqualStrings("#ffffff", palette.get("255").?);
}

test "attach request exposes explicit protocol modes as a generated enum" {
    try std.testing.expectEqualStrings(
        "bytes",
        protocol.AttachSurfaceRequestMode.bytes.toWire(),
    );
    try std.testing.expectEqualStrings(
        "render",
        protocol.AttachSurfaceRequestMode.render.toWire(),
    );
}

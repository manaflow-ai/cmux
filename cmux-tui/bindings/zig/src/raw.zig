const std = @import("std");

pub const wire = @import("raw/wire.zig");
pub const transport = @import("raw/transport.zig");
pub const client = @import("raw/client.zig");
pub const capabilities = @import("raw/capabilities.zig");
pub const provider = @import("raw/provider.zig");
pub const protocol = @import("raw/generated/protocol.zig");

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
    _ = @import("raw/authority_test.zig");
    _ = @import("raw/provider_test.zig");
    _ = @import("raw/stream_client_test.zig");
    _ = @import("raw/wire_presence_test.zig");
    _ = @import("raw/generated/presence_test.zig");
    std.testing.refAllDecls(protocol);
    try std.testing.expectEqual(@as(usize, 103), protocol.command_count);
    for ([_][]const u8{
        "browser-frame-presented",
        "browser-key-press",
        "browser-mouse-guarded",
        "browser-wheel-guarded",
        "clear-history",
        "new-pane-right",
        "set-viewport-pane-width",
        "undo-layout",
    }) |expected| {
        var found = false;
        for (protocol.commands) |command| {
            if (std.mem.eql(u8, command.name, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 46), protocol.event_count);
}

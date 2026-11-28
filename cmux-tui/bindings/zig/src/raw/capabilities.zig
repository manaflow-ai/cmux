const std = @import("std");

pub fn hasCapability(
    capabilities: []const []const u8,
    required: []const u8,
) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, required)) return true;
    }
    return false;
}

pub fn requireCapability(
    capabilities: []const []const u8,
    required: []const u8,
) error{MissingCapability}!void {
    if (!hasCapability(capabilities, required)) {
        return error.MissingCapability;
    }
}

test "capability helpers use exact wire names" {
    const capabilities = [_][]const u8{
        "workspace-registry-v1",
        "provider-managed-workspace-authority-v2",
    };
    try std.testing.expect(hasCapability(
        &capabilities,
        "workspace-registry-v1",
    ));
    try std.testing.expect(!hasCapability(
        &capabilities,
        "workspace-registry",
    ));
    try requireCapability(
        &capabilities,
        "provider-managed-workspace-authority-v2",
    );
    try std.testing.expectError(
        error.MissingCapability,
        requireCapability(&capabilities, "missing"),
    );
}

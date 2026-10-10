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

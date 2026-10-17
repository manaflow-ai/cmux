//! Bounded machine-catalog values. Borrowed strings retain the response arena's
//! lifetime; the capability list stores its slice table by value, with no allocation.
const std = @import("std");
const raw = @import("../raw.zig");

/// Explicit response format; catalog metadata grants no execution rights.
pub const MachineReadOptions = struct { catalog: bool = false };

pub fn addCatalog(params: *raw.wire.Object, options: MachineReadOptions) !void {
    if (options.catalog) try params.put("catalog", .{ .bool = true });
}

pub fn Models(comptime MachineId: type) type {
    return struct {
        pub const MachineOrigin = union(enum) {
            local,
            cloud,
            ssh,
            server,
            unknown: []const u8,

            pub fn wireName(self: MachineOrigin) []const u8 {
                return switch (self) {
                    .local => "local",
                    .cloud => "cloud",
                    .ssh => "ssh",
                    .server => "server",
                    .unknown => |value| value,
                };
            }
        };

        pub const MachineStatus = union(enum) {
            running,
            connecting,
            sleeping,
            stopped,
            unavailable,
            unknown: []const u8,

            pub fn wireName(self: MachineStatus) []const u8 {
                return switch (self) {
                    .running => "running",
                    .connecting => "connecting",
                    .sleeping => "sleeping",
                    .stopped => "stopped",
                    .unavailable => "unavailable",
                    .unknown => |value| value,
                };
            }
        };

        pub const MachinePlatform = struct {
            os: ?[]const u8 = null,
            arch: ?[]const u8 = null,
        };

        pub const MachineCapabilityList = struct {
            values: [16][]const u8 = undefined,
            len: usize = 0,

            pub fn slice(self: *const MachineCapabilityList) []const []const u8 {
                return self.values[0..self.len];
            }

            pub fn contains(self: *const MachineCapabilityList, capability: []const u8) bool {
                for (self.slice()) |value| {
                    if (std.mem.eql(u8, value, capability)) return true;
                }
                return false;
            }
        };

        pub const MachineSnapshot = struct {
            id: MachineId,
            name: []const u8,
            origin: MachineOrigin,
            status: MachineStatus,
            connectable: bool,
            deleted: bool,
            recoverable: bool,
            extra: ?raw.wire.Object,
            platform: ?MachinePlatform = null,
            capabilities: MachineCapabilityList = .{},
        };

        pub fn decode(value: raw.wire.Value) !MachineSnapshot {
            const object = try objectValue(value);
            try only(object, &.{ "id", "name", "origin", "status", "connectable", "deleted", "recoverable", "extra", "platform", "capabilities" });
            var platform: ?MachinePlatform = null;
            if (object.get("platform")) |field| {
                if (field != .null) {
                    const fields = try objectValue(field);
                    try only(fields, &.{ "os", "arch" });
                    platform = .{
                        .os = try optionalString(fields, "os"),
                        .arch = try optionalString(fields, "arch"),
                    };
                }
            }
            var capabilities: MachineCapabilityList = .{};
            if (object.get("capabilities")) |field| {
                const array = switch (field) {
                    .array => |items| items,
                    else => return error.ExpectedArray,
                };
                if (array.items.len > capabilities.values.len) return error.TooManyMachineCapabilities;
                for (array.items) |item| {
                    capabilities.values[capabilities.len] = switch (item) {
                        .string => |text| text,
                        else => return error.ExpectedString,
                    };
                    capabilities.len += 1;
                }
            }
            var extra: ?raw.wire.Object = null;
            if (object.get("extra")) |field| {
                extra = switch (field) {
                    .null => null,
                    .object => |fields| fields,
                    else => return error.ExpectedObject,
                };
            }
            return .{
                .id = try MachineId.parse(try string(object, "id")),
                .name = try string(object, "name"),
                .origin = origin(try string(object, "origin")),
                .status = status(try string(object, "status")),
                .connectable = try boolean(object, "connectable"),
                .deleted = try boolean(object, "deleted"),
                .recoverable = try boolean(object, "recoverable"),
                .extra = extra,
                .platform = platform,
                .capabilities = capabilities,
            };
        }

        fn objectValue(value: raw.wire.Value) !raw.wire.Object {
            return switch (value) {
                .object => |fields| fields,
                else => error.ExpectedObject,
            };
        }

        fn string(object: raw.wire.Object, key: []const u8) ![]const u8 {
            return switch (object.get(key) orelse return error.MissingField) {
                .string => |text| text,
                else => error.ExpectedString,
            };
        }

        fn optionalString(object: raw.wire.Object, key: []const u8) !?[]const u8 {
            return switch (object.get(key) orelse return null) {
                .null => null,
                .string => |text| text,
                else => error.ExpectedString,
            };
        }

        fn boolean(object: raw.wire.Object, key: []const u8) !bool {
            return switch (object.get(key) orelse return error.MissingField) {
                .bool => |result| result,
                else => error.ExpectedBool,
            };
        }

        fn only(object: raw.wire.Object, allowed: []const []const u8) !void {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var found = false;
                for (allowed) |key| {
                    if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnexpectedField;
            }
        }

        fn origin(value: []const u8) MachineOrigin {
            inline for (.{ "local", "cloud", "ssh", "server" }) |name| {
                if (std.mem.eql(u8, value, name)) return @unionInit(MachineOrigin, name, {});
            }
            return .{ .unknown = value };
        }

        fn status(value: []const u8) MachineStatus {
            inline for (.{ "running", "connecting", "sleeping", "stopped", "unavailable" }) |name| {
                if (std.mem.eql(u8, value, name)) return @unionInit(MachineStatus, name, {});
            }
            return .{ .unknown = value };
        }
    };
}

test "machine catalog retains remote origins and nullable owner metadata" {
    const Model = Models(@import("../resource.zig").MachineId);
    for ([_][]const u8{ "local", "cloud", "ssh", "server" }) |machine_origin| {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"server\",\"origin\":\"{s}\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false,\"platform\":{{\"os\":\"linux\",\"arch\":null}},\"capabilities\":[\"terminal\"]}}",
            .{machine_origin},
        );
        defer std.testing.allocator.free(json);
        var owned = try raw.wire.parse(std.testing.allocator, json, .{});
        defer owned.deinit();
        const machine = try Model.decode(owned.value);
        try std.testing.expectEqualStrings(machine_origin, machine.origin.wireName());
        try std.testing.expectEqualStrings("linux", machine.platform.?.os.?);
        try std.testing.expect(machine.platform.?.arch == null);
        try std.testing.expect(machine.capabilities.contains("terminal"));
    }
}

test "machine catalog keeps legacy defaults and rejects untyped metadata" {
    const Model = Models(@import("../resource.zig").MachineId);
    const prefix = "{\"id\":\"machine_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"name\":\"local\",\"origin\":\"local\",\"status\":\"running\",\"connectable\":true,\"deleted\":false,\"recoverable\":false";
    var legacy = try raw.wire.parse(std.testing.allocator, prefix ++ "}", .{});
    defer legacy.deinit();
    const machine = try Model.decode(legacy.value);
    try std.testing.expect(machine.platform == null);
    try std.testing.expectEqual(@as(usize, 0), machine.capabilities.len);
    var invalid = try raw.wire.parse(std.testing.allocator, prefix ++ ",\"platform\":{\"path\":\"/private\"}}", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.UnexpectedField, Model.decode(invalid.value));
}

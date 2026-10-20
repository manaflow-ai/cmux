const std = @import("std");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;

pub const Limits = struct {
    max_frame_bytes: usize = 16 * 1024 * 1024,
    max_request_bytes: usize = 4 * 1024 * 1024,
    max_value_bytes: usize = 4 * 1024 * 1024,
    max_depth: usize = 64,
    max_pre_ack_events: usize = 4096,
    max_pre_ack_bytes: usize = 16 * 1024 * 1024,
};

pub fn Field(comptime T: type) type {
    return union(enum) {
        absent,
        null_value,
        value: T,

        pub const cmux_wire_field = true;

        pub fn some(value: T) @This() {
            return .{ .value = value };
        }

        pub fn nullValue() @This() {
            return .null_value;
        }
    };
}

pub fn Nullable(comptime T: type) type {
    return union(enum) {
        null_value,
        value: T,

        pub const cmux_wire_nullable = true;

        pub fn some(value: T) @This() {
            return .{ .value = value };
        }

        pub fn nullValue() @This() {
            return .null_value;
        }
    };
}

pub fn Map(comptime T: type) type {
    return struct {
        pub const Entry = struct {
            key: []const u8,
            value: T,
        };
        pub const cmux_wire_map = true;
        pub const ValueType = T;

        entries: []const Entry,

        pub fn get(self: @This(), key: []const u8) ?T {
            for (self.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }
    };
}

pub fn Decoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

pub const OwnedValue = struct {
    arena: std.heap.ArenaAllocator,
    value: Value,
    encoded_size: usize,

    pub fn deinit(self: *OwnedValue) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn Encoded(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

fn checkDepth(input: []const u8, max_depth: usize) !void {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (input) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return error.MaxDepthExceeded;
            },
            '}', ']' => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            else => {},
        }
    }
    if (in_string or depth != 0) return error.InvalidJson;
}

pub fn parse(
    allocator: std.mem.Allocator,
    input: []const u8,
    limits: Limits,
) !OwnedValue {
    if (input.len > limits.max_frame_bytes) return error.FrameTooLarge;
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    try checkDepth(input, limits.max_depth);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(
        Value,
        arena.allocator(),
        input,
        .{
            .allocate = .alloc_always,
            .max_value_len = limits.max_value_bytes,
            .parse_numbers = false,
            .duplicate_field_behavior = .@"error",
        },
    );
    return .{ .arena = arena, .value = value, .encoded_size = input.len };
}

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: Value) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn decodeBase64Alloc(
    allocator: std.mem.Allocator,
    encoded: []const u8,
) ![]u8 {
    const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, size);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    return decoded;
}

pub fn encodeBase64Alloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]u8 {
    const encoded = try allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(bytes.len),
    );
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn numberString(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn isField(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => @hasDecl(T, "cmux_wire_field"),
        else => false,
    };
}

fn isNullable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => @hasDecl(T, "cmux_wire_nullable"),
        else => false,
    };
}

fn isMap(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "cmux_wire_map"),
        else => false,
    };
}

fn isCustomUnion(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"union" => @hasDecl(T, "cmux_wire_custom_union"),
        else => false,
    };
}

fn unionPayloadType(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.type;
    }
    @compileError("missing union payload " ++ name ++ " in " ++ @typeName(T));
}

pub fn objectHas(value: Value, key: []const u8) bool {
    return switch (value) {
        .object => |object| object.get(key) != null,
        else => false,
    };
}

pub fn objectString(value: Value, key: []const u8) ![]const u8 {
    const object = switch (value) {
        .object => |raw| raw,
        else => return error.ExpectedObject,
    };
    const field = object.get(key) orelse return error.MissingField;
    return switch (field) {
        .string => |raw| raw,
        else => error.ExpectedString,
    };
}

pub fn encodeTagged(
    allocator: std.mem.Allocator,
    tag: []const u8,
    tag_value: []const u8,
    payload: anytype,
) !Value {
    const encoded = try encodeValue(allocator, payload);
    var object = switch (encoded) {
        .object => |raw| raw,
        else => return error.ExpectedObject,
    };
    try object.put(
        try allocator.dupe(u8, tag),
        .{ .string = try allocator.dupe(u8, tag_value) },
    );
    return .{ .object = object };
}

pub fn encodeValue(
    allocator: std.mem.Allocator,
    value: anytype,
) anyerror!Value {
    const T = @TypeOf(value);
    if (T == Value) return try cloneValue(allocator, value);

    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        .int => |info| blk: {
            if (info.signedness == .signed) {
                break :blk .{ .number_string = try numberString(allocator, value) };
            }
            break :blk .{ .number_string = try numberString(allocator, value) };
        },
        .comptime_int => .{ .number_string = try numberString(allocator, value) },
        .float, .comptime_float => .{ .float = @floatCast(value) },
        .optional => {
            if (value) |inner| {
                return encodeValue(allocator, inner);
            }
            return .null;
        },
        .@"enum" => {
            if (@hasDecl(T, "toWire")) {
                return .{ .string = try allocator.dupe(u8, value.toWire()) };
            }
            return .{ .string = try allocator.dupe(u8, @tagName(value)) };
        },
        .pointer => |pointer| blk: {
            if (pointer.size == .one) {
                break :blk try encodeValue(allocator, value.*);
            }
            if (pointer.size != .slice) {
                @compileError("unsupported cmux wire pointer");
            }
            if (pointer.child == u8) {
                break :blk .{ .string = try allocator.dupe(u8, value) };
            }
            var array = std.json.Array.init(allocator);
            for (value) |item| {
                try array.append(try encodeValue(allocator, item));
            }
            break :blk .{ .array = array };
        },
        .array => blk: {
            var array = std.json.Array.init(allocator);
            for (value) |item| {
                try array.append(try encodeValue(allocator, item));
            }
            break :blk .{ .array = array };
        },
        .@"struct" => blk: {
            if (comptime isMap(T)) {
                var object = Object.init(allocator);
                for (value.entries) |entry| {
                    try object.put(
                        try allocator.dupe(u8, entry.key),
                        try encodeValue(allocator, entry.value),
                    );
                }
                break :blk .{ .object = object };
            }
            var object = Object.init(allocator);
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const field_value = @field(value, field.name);
                const FieldType = field.type;
                if (comptime isField(FieldType)) {
                    switch (field_value) {
                        .absent => {},
                        .null_value => try object.put(field.name, .null),
                        .value => |inner| try object.put(
                            field.name,
                            try encodeValue(allocator, inner),
                        ),
                    }
                } else if (@typeInfo(FieldType) == .optional and field_value == null) {
                    // Optional null means the wire property is absent.
                } else {
                    try object.put(
                        field.name,
                        try encodeValue(allocator, field_value),
                    );
                }
            }
            break :blk .{ .object = object };
        },
        .@"union" => blk: {
            if (comptime isCustomUnion(T)) {
                break :blk try value.cmuxEncode(allocator);
            }
            if (comptime isNullable(T)) {
                break :blk switch (value) {
                    .null_value => .null,
                    .value => |inner| try encodeValue(allocator, inner),
                };
            }
            @compileError("unsupported cmux wire union");
        },
        else => @compileError("unsupported cmux wire type " ++ @typeName(T)),
    };
}

pub fn encode(allocator: std.mem.Allocator, value: anytype) !Encoded(Value) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const encoded = try encodeValue(arena.allocator(), value);
    return .{
        .arena = arena,
        .value = encoded,
    };
}

fn integer(comptime T: type, value: Value) !T {
    const text = switch (value) {
        .number_string => |raw| raw,
        .integer => |raw| return std.math.cast(T, raw) orelse error.IntegerOverflow,
        else => return error.ExpectedInteger,
    };
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow => error.IntegerOverflow,
        error.InvalidCharacter => error.ExpectedInteger,
    };
}

fn float(comptime T: type, value: Value) !T {
    return switch (value) {
        .float => |raw| @floatCast(raw),
        .integer => |raw| @floatFromInt(raw),
        .number_string => |raw| std.fmt.parseFloat(T, raw) catch error.ExpectedNumber,
        else => error.ExpectedNumber,
    };
}

fn defaultOrMissing(comptime field: std.builtin.Type.StructField) !field.type {
    if (field.defaultValue()) |value| return value;
    if (@typeInfo(field.type) == .optional) return null;
    if (comptime isField(field.type)) return .absent;
    return error.MissingField;
}

fn rejectExplicitNulls(comptime T: type, object: Object) !void {
    if (comptime !@hasDecl(T, "cmux_wire_optional_nonnull_fields")) return;
    inline for (T.cmux_wire_optional_nonnull_fields) |field_name| {
        if (object.get(field_name)) |raw| {
            if (raw == .null) return error.UnexpectedNull;
        }
    }
}

pub fn decodeLeaky(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: Value,
) anyerror!T {
    if (T == Value) return try cloneValue(allocator, value);

    return switch (@typeInfo(T)) {
        .bool => switch (value) {
            .bool => |raw| raw,
            else => error.ExpectedBoolean,
        },
        .int => try integer(T, value),
        .float => try float(T, value),
        .optional => |optional| switch (value) {
            .null => null,
            else => try decodeLeaky(optional.child, allocator, value),
        },
        .@"enum" => switch (value) {
            .string => |raw| if (@hasDecl(T, "fromWire"))
                try T.fromWire(raw)
            else
                std.meta.stringToEnum(T, raw) orelse error.UnknownEnumValue,
            else => error.ExpectedString,
        },
        .pointer => |pointer| blk: {
            if (pointer.size == .one) {
                const result = try allocator.create(pointer.child);
                result.* = try decodeLeaky(pointer.child, allocator, value);
                break :blk result;
            }
            if (pointer.size != .slice) {
                @compileError("unsupported cmux wire pointer");
            }
            if (pointer.child == u8) {
                break :blk switch (value) {
                    .string => |raw| try allocator.dupe(u8, raw),
                    else => error.ExpectedString,
                };
            }
            const raw = switch (value) {
                .array => |array| array.items,
                else => return error.ExpectedArray,
            };
            const result = try allocator.alloc(pointer.child, raw.len);
            for (raw, result) |item, *destination| {
                destination.* = try decodeLeaky(pointer.child, allocator, item);
            }
            break :blk result;
        },
        .@"struct" => blk: {
            const object = switch (value) {
                .object => |raw| raw,
                else => return error.ExpectedObject,
            };
            if (comptime isMap(T)) {
                const entries = try allocator.alloc(T.Entry, object.count());
                var iterator = object.iterator();
                var index: usize = 0;
                while (iterator.next()) |entry| : (index += 1) {
                    entries[index] = .{
                        .key = try allocator.dupe(u8, entry.key_ptr.*),
                        .value = try decodeLeaky(
                            T.ValueType,
                            allocator,
                            entry.value_ptr.*,
                        ),
                    };
                }
                break :blk .{ .entries = entries };
            }
            try rejectExplicitNulls(T, object);
            var result: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (object.get(field.name)) |raw| {
                    if (comptime isField(field.type)) {
                        @field(result, field.name) = switch (raw) {
                            .null => .null_value,
                            else => .{
                                .value = try decodeLeaky(
                                    unionPayloadType(field.type, "value"),
                                    allocator,
                                    raw,
                                ),
                            },
                        };
                    } else {
                        @field(result, field.name) = try decodeLeaky(
                            field.type,
                            allocator,
                            raw,
                        );
                    }
                } else {
                    @field(result, field.name) = try defaultOrMissing(field);
                }
            }
            break :blk result;
        },
        .@"union" => blk: {
            if (comptime isCustomUnion(T)) {
                break :blk try T.cmuxDecode(allocator, value);
            }
            if (comptime isNullable(T)) {
                break :blk switch (value) {
                    .null => .null_value,
                    else => .{
                        .value = try decodeLeaky(
                            unionPayloadType(T, "value"),
                            allocator,
                            value,
                        ),
                    },
                };
            }
            @compileError("unsupported cmux wire union");
        },
        else => @compileError("unsupported cmux decode type " ++ @typeName(T)),
    };
}

pub fn decode(
    comptime T: type,
    allocator: std.mem.Allocator,
    value: Value,
) !Decoded(T) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const decoded = try decodeLeaky(T, arena.allocator(), value);
    return .{
        .arena = arena,
        .value = decoded,
    };
}

pub fn cloneValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .null => .null,
        .bool => |raw| .{ .bool = raw },
        .integer => |raw| .{ .integer = raw },
        .float => |raw| .{ .float = raw },
        .number_string => |raw| .{
            .number_string = try allocator.dupe(u8, raw),
        },
        .string => |raw| .{ .string = try allocator.dupe(u8, raw) },
        .array => |raw| blk: {
            var result = std.json.Array.init(allocator);
            for (raw.items) |item| {
                try result.append(try cloneValue(allocator, item));
            }
            break :blk .{ .array = result };
        },
        .object => |raw| blk: {
            var result = Object.init(allocator);
            var iterator = raw.iterator();
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

pub fn eventName(value: Value) ![]const u8 {
    const object = switch (value) {
        .object => |raw| raw,
        else => return error.ExpectedObject,
    };
    const event = object.get("event") orelse return error.MissingEventName;
    return switch (event) {
        .string => |name| name,
        else => error.ExpectedString,
    };
}

test "uint64 values round trip exactly" {
    const allocator = std.testing.allocator;
    var parsed = try parse(
        allocator,
        "{\"id\":18446744073709551615}",
        .{},
    );
    defer parsed.deinit();
    const id = parsed.value.object.get("id").?;
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try decodeLeaky(u64, allocator, id),
    );
    const rendered = try stringifyAlloc(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "{\"id\":18446744073709551615}",
        rendered,
    );
}

test "parser enforces depth and utf8 limits" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MaxDepthExceeded,
        parse(allocator, "[[[]]]", .{ .max_depth = 2 }),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        parse(allocator, &[_]u8{ '"', 0xff, '"' }, .{}),
    );
}

test "optional and nullable properties preserve wire presence" {
    const Request = struct {
        omitted: Field(u64) = .absent,
        explicit_null: Nullable([]const u8),
        exact: u64,
    };
    var encoded = try encode(std.testing.allocator, Request{
        .explicit_null = .null_value,
        .exact = std.math.maxInt(u64),
    });
    defer encoded.deinit();
    const object = encoded.value.object;
    try std.testing.expect(object.get("omitted") == null);
    try std.testing.expect(object.get("explicit_null").? == .null);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try decodeLeaky(u64, std.testing.allocator, object.get("exact").?),
    );
}

test "base64 helpers own decoded and encoded bytes" {
    const encoded = try encodeBase64Alloc(std.testing.allocator, "cmux");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("Y211eA==", encoded);
    const decoded = try decodeBase64Alloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("cmux", decoded);
}

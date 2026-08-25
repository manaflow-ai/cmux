const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const transport = @import("transport.zig");
const transport_hook_test = if (builtin.is_test)
    @import("transport_hook_test.zig")
else
    struct {};

pub const Connection = transport.Connection;
pub const Limits = wire.Limits;

/// Controls which generated authority classes may reach the transport.
///
/// `.local` permits control, frontend, and local-admin commands. The explicit
/// `.provider_authority` policy adds provider-authority commands.
pub const AuthorityPolicy = enum {
    local,
    provider_authority,

    fn allowsAuthority(
        self: AuthorityPolicy,
        authority: []const u8,
    ) bool {
        if (std.mem.eql(u8, authority, "control") or
            std.mem.eql(u8, authority, "frontend") or
            std.mem.eql(u8, authority, "local-admin"))
        {
            return true;
        }
        return self == .provider_authority and
            std.mem.eql(u8, authority, "provider-authority");
    }
};

pub const FieldRequirement = struct {
    name: []const u8,
    since: ?u16 = null,
    capability: ?[]const u8 = null,
};

pub const CommandRequirements = struct {
    name: []const u8,
    authority: []const u8,
    since: u16,
    capability: ?[]const u8 = null,
    fields: []const FieldRequirement = &.{},
};

pub const UncheckedCommand = struct {
    name: []const u8,
    authority: []const u8,
};

pub const OwnedRemoteError = struct {
    allocator: std.mem.Allocator,
    message: []u8,

    pub fn deinit(self: *OwnedRemoteError) void {
        secureFreeBytes(self.allocator, self.message);
        self.* = undefined;
    }
};

pub const Options = struct {
    socket_path: ?[]const u8 = null,
    session: []const u8 = "main",
    /// Bounds socket establishment and each later transport read or write.
    /// `null` disables transport deadlines.
    timeout_ms: ?u32 = 10_000,
    limits: Limits = .{},
    authority_policy: AuthorityPolicy = .local,
};

const Pending = struct {
    message: wire.OwnedValue,
};

const NegotiationResult = struct {
    protocol: u32,
    capabilities: []const []const u8 = &.{},
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection: Connection,
    timeout_ms: ?u32,
    limits: Limits,
    authority_policy: AuthorityPolicy,
    next_id: u64 = 1,
    inbound: std.ArrayList(u8) = .empty,
    call_mutex: std.Thread.Mutex = .{},
    close_mutex: std.Thread.Mutex = .{},
    closed: bool = false,
    streaming: bool = false,
    last_remote_error: ?[]u8 = null,
    negotiated_protocol: ?u32 = null,
    negotiated_capabilities: std.ArrayList([]u8) = .empty,
    reconnect_socket_path: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Connection,
        options: Options,
    ) Client {
        return .{
            .allocator = allocator,
            .connection = connection,
            .timeout_ms = options.timeout_ms,
            .limits = options.limits,
            .authority_policy = options.authority_policy,
        };
    }

    pub fn connect(
        allocator: std.mem.Allocator,
        options: Options,
    ) !Client {
        const path = try transport.resolveSocketPath(
            allocator,
            options.socket_path,
            options.session,
        );
        defer allocator.free(path);
        const resolved: transport.ResolvedConnection = if (options.socket_path == null and !(try transport.hasSocketOverride()))
            try transport.connectResolvedWithLegacyFallback(allocator, path, options.session, options.timeout_ms)
        else blk: {
            var connection = try transport.connectUnixWithTimeout(allocator, path, options.timeout_ms);
            errdefer connection.deinit();
            break :blk .{ .connection = connection, .path = try allocator.dupe(u8, path) };
        };
        var connection = resolved.connection;
        const effective_path = resolved.path;
        errdefer connection.deinit();
        var result = init(allocator, connection, options);
        result.reconnect_socket_path = effective_path;
        return result;
    }

    pub fn close(self: *Client) void {
        self.close_mutex.lock();
        defer self.close_mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        self.connection.close();
    }

    pub fn deinit(self: *Client) void {
        self.close();
        self.connection.deinit();
        self.inbound.deinit(self.allocator);
        self.clearRemoteError();
        self.clearNegotiation();
        if (self.reconnect_socket_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Opens an independent client on the same resolved Unix socket.
    ///
    /// Use the returned client for a subscription or attachment so its stream
    /// lifecycle does not consume this command client.
    pub fn openStreamClient(self: *const Client) !Client {
        const path = self.reconnect_socket_path orelse
            return error.StreamClientUnavailable;
        return connect(self.allocator, .{
            .socket_path = path,
            .timeout_ms = self.timeout_ms,
            .limits = self.limits,
            .authority_policy = self.authority_policy,
        });
    }

    /// Borrows the latest remote error until the next call, `takeRemoteError`,
    /// or `deinit`. A new call clears the previous message before I/O starts.
    pub fn lastRemoteError(self: *const Client) ?[]const u8 {
        return self.last_remote_error;
    }

    /// Transfers the latest remote error to the caller. The caller must call
    /// `deinit` on the returned value.
    pub fn takeRemoteError(self: *Client) ?OwnedRemoteError {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        const message = self.last_remote_error orelse return null;
        self.last_remote_error = null;
        return .{
            .allocator = self.allocator,
            .message = message,
        };
    }

    fn clearRemoteError(self: *Client) void {
        if (self.last_remote_error) |message| {
            secureFreeBytes(self.allocator, message);
            self.last_remote_error = null;
        }
    }

    fn setRemoteError(self: *Client, message: []const u8) !void {
        self.clearRemoteError();
        self.last_remote_error = try self.allocator.dupe(u8, message);
    }

    fn requestValue(
        self: *Client,
        allocator: std.mem.Allocator,
        id: u64,
        command: []const u8,
        request: anytype,
    ) !wire.Value {
        const encoded = try wire.encodeValue(allocator, request);
        var object = switch (encoded) {
            .object => |value| value,
            else => return error.RequestMustBeObject,
        };
        try object.put(
            "id",
            .{ .number_string = try std.fmt.allocPrint(allocator, "{d}", .{id}) },
        );
        try object.put("cmd", .{ .string = try allocator.dupe(u8, command) });
        if (object.count() > 0) {
            try object.reIndex();
        }
        _ = self;
        return .{ .object = object };
    }

    fn sendRequest(
        self: *Client,
        command: []const u8,
        authority: []const u8,
        request: anytype,
    ) !u64 {
        try self.requireAuthority(command, authority);
        if (self.closed) return error.ConnectionClosed;
        if (self.streaming) return error.StreamActive;
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const value = try self.requestValue(
            arena.allocator(),
            id,
            command,
            request,
        );
        const encoded = try wire.stringifyAlloc(self.allocator, value);
        defer self.allocator.free(encoded);
        if (encoded.len > self.limits.max_request_bytes) {
            return error.RequestTooLarge;
        }
        self.connection.writeAll(encoded, self.timeout_ms) catch |failure| {
            self.close();
            return failure;
        };
        self.connection.writeAll("\n", self.timeout_ms) catch |failure| {
            self.close();
            return failure;
        };
        return id;
    }

    fn takeFrame(self: *Client) !?[]u8 {
        const newline = std.mem.indexOfScalar(u8, self.inbound.items, '\n') orelse {
            if (self.inbound.items.len > self.limits.max_frame_bytes) {
                return error.FrameTooLarge;
            }
            return null;
        };
        if (newline > self.limits.max_frame_bytes) return error.FrameTooLarge;
        const line_end = if (newline > 0 and self.inbound.items[newline - 1] == '\r')
            newline - 1
        else
            newline;
        const line = try self.allocator.dupe(u8, self.inbound.items[0..line_end]);
        const consumed = newline + 1;
        std.mem.copyForwards(
            u8,
            self.inbound.items[0 .. self.inbound.items.len - consumed],
            self.inbound.items[consumed..],
        );
        self.inbound.items.len -= consumed;
        return line;
    }

    fn readMessage(self: *Client) !wire.OwnedValue {
        while (true) {
            if (try self.takeFrame()) |frame| {
                defer self.allocator.free(frame);
                if (frame.len == 0) return error.EmptyFrame;
                return wire.parse(self.allocator, frame, self.limits);
            }
            var chunk: [8192]u8 = undefined;
            const count = try self.connection.read(&chunk, self.timeout_ms);
            if (count == 0) return error.ConnectionClosed;
            try self.inbound.appendSlice(self.allocator, chunk[0..count]);
            if (self.inbound.items.len > self.limits.max_frame_bytes and
                std.mem.indexOfScalar(u8, self.inbound.items, '\n') == null)
            {
                return error.FrameTooLarge;
            }
        }
    }

    fn responseMatches(value: wire.Value, id: u64) !bool {
        const object = switch (value) {
            .object => |raw| raw,
            else => return error.ExpectedObject,
        };
        const response_id = object.get("id") orelse return false;
        return try wire.decodeLeaky(u64, std.heap.page_allocator, response_id) == id;
    }

    fn responseData(self: *Client, value: wire.Value) !wire.Value {
        const object = switch (value) {
            .object => |raw| raw,
            else => return error.ExpectedObject,
        };
        const ok_value = object.get("ok") orelse return error.MissingResponseStatus;
        const ok = switch (ok_value) {
            .bool => |raw| raw,
            else => return error.InvalidResponseStatus,
        };
        if (!ok) {
            const raw_error = object.get("error") orelse return error.RemoteError;
            const message = switch (raw_error) {
                .string => |raw| raw,
                else => return error.RemoteError,
            };
            try self.setRemoteError(message);
            return error.RemoteError;
        }
        return object.get("data") orelse return error.MissingResponseData;
    }

    pub fn callTyped(
        self: *Client,
        comptime Result: type,
        comptime requirements: CommandRequirements,
        request: anytype,
    ) !wire.Decoded(Result) {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.clearRemoteError();
        try self.requireAuthority(
            requirements.name,
            requirements.authority,
        );

        if (comptime std.mem.eql(u8, requirements.name, "identify")) {
            var identity = try self.callUncheckedLocked(
                Result,
                requirements.name,
                requirements.authority,
                request,
            );
            errdefer identity.deinit();
            try self.storeNegotiation(
                identity.value.protocol,
                identity.value.capabilities orelse &.{},
            );
            return identity;
        }

        try self.ensureNegotiatedLocked();
        try self.validateRequirements(requirements, request);
        return self.callUncheckedLocked(
            Result,
            requirements.name,
            requirements.authority,
            request,
        );
    }

    /// Sends a raw command without protocol or capability checks.
    ///
    /// The authority policy still rejects known provider-authority commands.
    pub fn callUnchecked(
        self: *Client,
        comptime Result: type,
        command: UncheckedCommand,
        request: anytype,
    ) !wire.Decoded(Result) {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.clearRemoteError();
        return self.callUncheckedLocked(
            Result,
            command.name,
            command.authority,
            request,
        );
    }

    fn callUncheckedLocked(
        self: *Client,
        comptime Result: type,
        command: []const u8,
        authority: []const u8,
        request: anytype,
    ) !wire.Decoded(Result) {
        const id = try self.sendRequest(command, authority, request);
        while (true) {
            var message = try self.readMessage();
            defer message.deinit();
            if (try responseMatches(message.value, id)) {
                return wire.decode(
                    Result,
                    self.allocator,
                    try self.responseData(message.value),
                );
            }
            if (message.value == .object and
                message.value.object.get("event") != null)
            {
                continue;
            }
            return error.UnexpectedResponse;
        }
    }

    pub fn openStream(
        self: *Client,
        comptime requirements: CommandRequirements,
        request: anytype,
        terminal_event: ?[]const u8,
    ) !Stream {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.clearRemoteError();
        try self.requireAuthority(
            requirements.name,
            requirements.authority,
        );
        try self.ensureNegotiatedLocked();
        try self.validateRequirements(requirements, request);
        return self.openStreamUncheckedLocked(
            requirements.name,
            requirements.authority,
            request,
            terminal_event,
        );
    }

    /// Opens a raw stream without protocol or capability checks.
    ///
    /// The authority policy still rejects known provider-authority commands.
    pub fn openStreamUnchecked(
        self: *Client,
        command: UncheckedCommand,
        request: anytype,
        terminal_event: ?[]const u8,
    ) !Stream {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.clearRemoteError();
        return self.openStreamUncheckedLocked(
            command.name,
            command.authority,
            request,
            terminal_event,
        );
    }

    fn openStreamUncheckedLocked(
        self: *Client,
        command: []const u8,
        authority: []const u8,
        request: anytype,
        terminal_event: ?[]const u8,
    ) !Stream {
        const id = try self.sendRequest(command, authority, request);
        var pending: std.ArrayList(Pending) = .empty;
        errdefer {
            for (pending.items) |*item| item.message.deinit();
            pending.deinit(self.allocator);
        }
        var pending_bytes: usize = 0;
        while (true) {
            var message = try self.readMessage();
            if (try responseMatches(message.value, id)) {
                _ = try self.responseData(message.value);
                message.deinit();
                self.streaming = true;
                return .{
                    .client = self,
                    .pending = pending,
                    .terminal_event = terminal_event,
                };
            }
            if (message.value != .object or
                message.value.object.get("event") == null)
            {
                message.deinit();
                return error.UnexpectedResponse;
            }
            if (pending.items.len >= self.limits.max_pre_ack_events or
                pending_bytes + message.encoded_size > self.limits.max_pre_ack_bytes)
            {
                message.deinit();
                self.close();
                return error.PreAckBufferOverflow;
            }
            pending_bytes += message.encoded_size;
            try pending.append(self.allocator, .{ .message = message });
        }
    }

    /// Performs the lazy identify handshake without sending another command.
    pub fn negotiate(self: *Client) !void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        self.clearRemoteError();
        try self.ensureNegotiatedLocked();
    }

    pub fn negotiatedProtocol(self: *const Client) ?u32 {
        return self.negotiated_protocol;
    }

    pub fn hasNegotiatedCapability(
        self: *const Client,
        required: []const u8,
    ) bool {
        for (self.negotiated_capabilities.items) |capability| {
            if (std.mem.eql(u8, capability, required)) return true;
        }
        return false;
    }

    fn ensureNegotiatedLocked(self: *Client) !void {
        if (self.negotiated_protocol != null) return;
        var identity = try self.callUncheckedLocked(
            NegotiationResult,
            "identify",
            "control",
            .{},
        );
        defer identity.deinit();
        try self.storeNegotiation(
            identity.value.protocol,
            identity.value.capabilities,
        );
    }

    fn storeNegotiation(
        self: *Client,
        protocol: u32,
        capabilities: []const []const u8,
    ) !void {
        var copied: std.ArrayList([]u8) = .empty;
        errdefer freeCapabilities(self.allocator, &copied);
        try copied.ensureTotalCapacity(self.allocator, capabilities.len);
        for (capabilities) |capability| {
            copied.appendAssumeCapacity(
                try self.allocator.dupe(u8, capability),
            );
        }

        self.clearNegotiation();
        self.negotiated_protocol = protocol;
        self.negotiated_capabilities = copied;
    }

    fn clearNegotiation(self: *Client) void {
        freeCapabilities(self.allocator, &self.negotiated_capabilities);
        self.negotiated_protocol = null;
    }

    fn validateRequirements(
        self: *const Client,
        comptime requirements: CommandRequirements,
        request: anytype,
    ) !void {
        const protocol = self.negotiated_protocol orelse
            return error.NotNegotiated;
        if (protocol < requirements.since) {
            return error.UnsupportedProtocol;
        }
        if (requirements.capability) |capability| {
            if (!self.hasNegotiatedCapability(capability)) {
                return error.MissingCapability;
            }
        }
        inline for (requirements.fields) |field| {
            if (requestFieldPresent(request, field.name)) {
                if (field.since) |since| {
                    if (protocol < since) {
                        return error.UnsupportedFieldProtocol;
                    }
                }
                if (field.capability) |capability| {
                    if (!self.hasNegotiatedCapability(capability)) {
                        return error.MissingFieldCapability;
                    }
                }
            }
        }
    }

    fn requireAuthority(
        self: *const Client,
        command: []const u8,
        authority: []const u8,
    ) !void {
        if (requiresProviderAuthority(command) and
            !std.mem.eql(u8, authority, "provider-authority"))
        {
            return error.ProviderAuthorityDenied;
        }
        if (self.authority_policy.allowsAuthority(authority)) return;
        if (std.mem.eql(u8, authority, "provider-authority")) {
            return error.ProviderAuthorityDenied;
        }
        return error.AuthorityDenied;
    }
};

fn freeCapabilities(
    allocator: std.mem.Allocator,
    capabilities: *std.ArrayList([]u8),
) void {
    for (capabilities.items) |capability| allocator.free(capability);
    capabilities.deinit(allocator);
    capabilities.* = .empty;
}

fn requestFieldPresent(
    request: anytype,
    comptime name: []const u8,
) bool {
    const value = @field(request, name);
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .optional => value != null,
        .@"union" => if (@hasDecl(T, "cmux_wire_field"))
            std.meta.activeTag(value) != .absent
        else
            true,
        else => true,
    };
}

fn secureFreeBytes(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

fn requiresProviderAuthority(command: []const u8) bool {
    // Generated calls carry authority metadata. This defense also prevents an
    // unchecked caller from misclassifying a current provider command.
    return std.mem.eql(u8, command, "close-provider-managed-workspace") or
        std.mem.eql(u8, command, "mark-workspaces-provider-managed") or
        std.mem.eql(u8, command, "rename-provider-managed-workspace");
}

pub const Stream = struct {
    client: *Client,
    pending: std.ArrayList(Pending),
    terminal_event: ?[]const u8,
    ended: bool = false,
    closed: bool = false,

    pub fn next(self: *Stream) !?wire.OwnedValue {
        if (self.ended or self.closed) return null;
        var message = if (self.pending.items.len > 0)
            self.pending.orderedRemove(0).message
        else
            try self.client.readMessage();
        errdefer message.deinit();
        const name = try wire.eventName(message.value);
        if (std.mem.eql(u8, name, "overflow") or
            (self.terminal_event != null and
                std.mem.eql(u8, name, self.terminal_event.?)))
        {
            self.ended = true;
        }
        return message;
    }

    /// Cancels a blocking next call by shutting down the owned connection.
    pub fn close(self: *Stream) void {
        if (self.closed) return;
        self.closed = true;
        self.client.close();
    }

    pub fn deinit(self: *Stream) void {
        self.close();
        for (self.pending.items) |*item| item.message.deinit();
        self.pending.deinit(self.client.allocator);
        self.client.streaming = false;
        self.* = undefined;
    }
};

const ScriptedConnection = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize = 0,
    chunk_size: usize,
    output: std.ArrayList(u8) = .empty,
    closed: bool = false,
    write_calls: usize = 0,
    fail_write_call: ?usize = null,

    fn create(input: []const u8, chunk_size: usize) !*ScriptedConnection {
        const state = try std.testing.allocator.create(ScriptedConnection);
        state.* = .{
            .allocator = std.testing.allocator,
            .input = input,
            .chunk_size = chunk_size,
        };
        return state;
    }

    pub fn read(
        self: *ScriptedConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = timeout_ms;
        if (self.closed) return error.ConnectionClosed;
        if (self.cursor == self.input.len) return 0;
        const count = @min(
            @min(buffer.len, self.chunk_size),
            self.input.len - self.cursor,
        );
        @memcpy(buffer[0..count], self.input[self.cursor..][0..count]);
        self.cursor += count;
        return count;
    }

    pub fn writeAll(
        self: *ScriptedConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = timeout_ms;
        if (self.closed) return error.ConnectionClosed;
        self.write_calls += 1;
        if (self.fail_write_call == self.write_calls) {
            return error.InjectedWriteFailure;
        }
        try self.output.appendSlice(self.allocator, bytes);
    }

    pub fn close(self: *ScriptedConnection) void {
        self.closed = true;
    }

    pub fn deinit(self: *ScriptedConnection) void {
        const allocator = self.allocator;
        self.output.deinit(allocator);
        allocator.destroy(self);
    }
};

const TimeoutConnection = struct {
    allocator: std.mem.Allocator,

    fn create() !*TimeoutConnection {
        const state = try std.testing.allocator.create(TimeoutConnection);
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(self: *TimeoutConnection, buffer: []u8, timeout_ms: ?u32) !usize {
        _ = self;
        _ = buffer;
        _ = timeout_ms;
        return error.Timeout;
    }

    pub fn writeAll(
        self: *TimeoutConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = self;
        _ = bytes;
        _ = timeout_ms;
    }

    pub fn close(self: *TimeoutConnection) void {
        _ = self;
    }

    pub fn deinit(self: *TimeoutConnection) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const BlockingConnection = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    entered: bool = false,
    closed: bool = false,

    fn create() !*BlockingConnection {
        const state = try std.testing.allocator.create(BlockingConnection);
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(
        self: *BlockingConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = buffer;
        _ = timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entered = true;
        self.condition.broadcast();
        while (!self.closed) self.condition.wait(&self.mutex);
        return error.ConnectionClosed;
    }

    pub fn writeAll(
        self: *BlockingConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = self;
        _ = bytes;
        _ = timeout_ms;
    }

    pub fn close(self: *BlockingConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.condition.broadcast();
    }

    pub fn waitUntilReading(self: *BlockingConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.entered) self.condition.wait(&self.mutex);
    }

    pub fn deinit(self: *BlockingConnection) void {
        const allocator = self.allocator;
        self.close();
        allocator.destroy(self);
    }
};

test "partial frames and exact typed response" {
    const state = try ScriptedConnection.create(
        "{\"id\":1,\"ok\":true,\"data\":{\"value\":18446744073709551615}}\n",
        3,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();
    const Result = struct { value: u64 };
    var result = try client.callUnchecked(
        Result,
        .{ .name = "test", .authority = "control" },
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), result.value.value);
}

test "pre-ack events preserve order and overflow terminates stream" {
    const state = try ScriptedConnection.create(
        "{\"event\":\"status\",\"message\":\"ready\"}\n" ++
            "{\"id\":1,\"ok\":true,\"data\":{}}\n" ++
            "{\"event\":\"overflow\",\"dropped\":2}\n" ++
            "{\"event\":\"status\",\"message\":\"ignored\"}\n",
        7,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();
    var stream = try client.openStreamUnchecked(
        .{ .name = "subscribe", .authority = "control" },
        .{},
        null,
    );
    defer stream.deinit();

    var first = (try stream.next()).?;
    defer first.deinit();
    try std.testing.expectEqualStrings("status", try wire.eventName(first.value));

    var overflow = (try stream.next()).?;
    defer overflow.deinit();
    try std.testing.expectEqualStrings(
        "overflow",
        try wire.eventName(overflow.value),
    );
    try std.testing.expect((try stream.next()) == null);
}

test "oversized unterminated frame is rejected" {
    const state = try ScriptedConnection.create("12345", 5);
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{ .limits = .{ .max_frame_bytes = 4 } },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.FrameTooLarge,
        client.callUnchecked(
            struct {},
            .{ .name = "test", .authority = "control" },
            .{},
        ),
    );
}

test "transport timeout is surfaced" {
    const state = try TimeoutConnection.create();
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{ .timeout_ms = 1 },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.Timeout,
        client.callUnchecked(
            struct {},
            .{ .name = "test", .authority = "control" },
            .{},
        ),
    );
}

test "raw Client connect bounds a stalled Unix socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/raw-client-connect-timeout.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{ .kernel_backlog = 0 });
    defer server.deinit();
    var blocker = try transport.connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer blocker.deinit();

    const pipe_fds = try std.posix.pipe2(.{
        .CLOEXEC = true,
        .NONBLOCK = true,
    });
    defer std.posix.close(pipe_fds[0]);
    defer std.posix.close(pipe_fds[1]);
    var fill: [64 * 1024]u8 = undefined;
    @memset(&fill, 0x5a);
    while (true) {
        _ = std.posix.write(pipe_fds[1], &fill) catch |failure| switch (failure) {
            error.WouldBlock => break,
            else => return failure,
        };
    }

    var hook = transport_hook_test.ConnectHook{
        .poll_fd_override = pipe_fds[1],
        .fail_ready_poll = true,
    };
    hook.continue_wait.set();
    transport_hook_test.connect_hook = &hook;
    defer transport_hook_test.connect_hook = null;

    const PendingConnect = struct {
        path: []const u8,
        client: ?Client = null,
        failure: ?anyerror = null,
        elapsed_ns: u64 = 0,

        fn run(self: *@This()) void {
            var timer = std.time.Timer.start() catch |failure| {
                self.failure = failure;
                return;
            };
            self.client = Client.connect(std.testing.allocator, .{
                .socket_path = self.path,
                .timeout_ms = 20,
            }) catch |failure| {
                self.failure = failure;
                self.elapsed_ns = timer.read();
                return;
            };
            self.elapsed_ns = timer.read();
        }
    };
    const Helpers = struct {
        fn drain(fd: std.posix.fd_t) void {
            var bytes: [64 * 1024]u8 = undefined;
            while (true) {
                const count = std.posix.read(fd, &bytes) catch return;
                if (count == 0) return;
            }
        }
    };
    var pending = PendingConnect{ .path = path };
    const thread = try std.Thread.spawn(.{}, PendingConnect.run, .{&pending});
    var joined = false;
    defer if (!joined) thread.join();
    var poll_released = false;
    defer if (!poll_released) Helpers.drain(pipe_fds[0]);

    try hook.entered_poll.timedWait(std.time.ns_per_s);
    std.Thread.sleep(100 * std.time.ns_per_ms);
    Helpers.drain(pipe_fds[0]);
    poll_released = true;
    thread.join();
    joined = true;
    defer if (pending.client) |*client| client.deinit();

    try std.testing.expectEqual(
        error.Timeout,
        pending.failure orelse return error.ExpectedTimeout,
    );
    try std.testing.expect(pending.elapsed_ns < 70 * std.time.ns_per_ms);
}

test "remote command errors preserve server text" {
    const state = try ScriptedConnection.create(
        "{\"id\":1,\"ok\":false,\"error\":\"workspace is stale\"}\n",
        64,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();
    try std.testing.expectError(
        error.RemoteError,
        client.callUnchecked(
            struct {},
            .{ .name = "test", .authority = "control" },
            .{},
        ),
    );
    try std.testing.expectEqualStrings(
        "workspace is stale",
        client.lastRemoteError().?,
    );
}

test "takeRemoteError transfers ownership exactly once" {
    const state = try ScriptedConnection.create(
        "{\"id\":1,\"ok\":false,\"error\":\"invalid authority\"}\n",
        64,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();
    try std.testing.expectError(
        error.RemoteError,
        client.callUnchecked(
            struct {},
            .{ .name = "test", .authority = "control" },
            .{},
        ),
    );

    var remote_error = client.takeRemoteError() orelse
        return error.ExpectedRemoteError;
    defer remote_error.deinit();
    try std.testing.expectEqualStrings(
        "invalid authority",
        remote_error.message,
    );
    try std.testing.expect(client.lastRemoteError() == null);
    try std.testing.expect(client.takeRemoteError() == null);
}

test "a new call clears stale remote text" {
    const state = try ScriptedConnection.create(
        "{\"id\":1,\"ok\":false,\"error\":\"first failed\"}\n" ++
            "{\"id\":2,\"ok\":true,\"data\":{}}\n",
        64,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();
    try std.testing.expectError(
        error.RemoteError,
        client.callUnchecked(
            struct {},
            .{ .name = "first", .authority = "control" },
            .{},
        ),
    );
    try std.testing.expect(client.lastRemoteError() != null);

    var result = try client.callUnchecked(
        struct {},
        .{ .name = "second", .authority = "control" },
        .{},
    );
    defer result.deinit();
    try std.testing.expect(client.lastRemoteError() == null);
}

test "request size is bounded before transport write" {
    const state = try ScriptedConnection.create("", 64);
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{ .limits = .{ .max_request_bytes = 8 } },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.RequestTooLarge,
        client.callUnchecked(
            struct { text: []const u8 },
            .{ .name = "test", .authority = "control" },
            .{ .text = "larger than the configured request bound" },
        ),
    );
}

test "framing write failure closes the raw client and preserves the error" {
    const state = try ScriptedConnection.create("", 64);
    state.fail_write_call = 2;
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{},
    );
    defer client.deinit();

    try std.testing.expectError(
        error.InjectedWriteFailure,
        client.callUnchecked(
            struct {},
            .{ .name = "first", .authority = "control" },
            .{},
        ),
    );
    try std.testing.expect(client.closed);
    try std.testing.expect(state.closed);
    const bytes_after_failure = state.output.items.len;
    try std.testing.expectError(
        error.ConnectionClosed,
        client.callUnchecked(
            struct {},
            .{ .name = "second", .authority = "control" },
            .{},
        ),
    );
    try std.testing.expectEqual(
        bytes_after_failure,
        state.output.items.len,
    );
}

test "close unblocks a pending read" {
    const state = try BlockingConnection.create();
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{ .timeout_ms = null },
    );
    defer client.deinit();
    const Context = struct {
        client: *Client,
        result_error: ?anyerror = null,

        fn run(context: *@This()) void {
            var result = context.client.callUnchecked(
                struct {},
                .{ .name = "blocking", .authority = "control" },
                .{},
            ) catch |err| {
                context.result_error = err;
                return;
            };
            result.deinit();
        }
    };
    var context = Context{ .client = &client };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    state.waitUntilReading();
    client.close();
    thread.join();
    try std.testing.expectEqual(error.ConnectionClosed, context.result_error.?);
}

test "pre-ack event bound closes the stream connection" {
    const state = try ScriptedConnection.create(
        "{\"event\":\"status\"}\n{\"id\":1,\"ok\":true,\"data\":{}}\n",
        64,
    );
    var client = Client.init(
        std.testing.allocator,
        Connection.from(state),
        .{ .limits = .{ .max_pre_ack_events = 0 } },
    );
    defer client.deinit();
    try std.testing.expectError(
        error.PreAckBufferOverflow,
        client.openStreamUnchecked(
            .{ .name = "subscribe", .authority = "control" },
            .{},
            null,
        ),
    );
    try std.testing.expect(client.closed);
}

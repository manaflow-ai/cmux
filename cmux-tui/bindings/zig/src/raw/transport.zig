const std = @import("std");

pub const VTable = struct {
    read: *const fn (*anyopaque, []u8, ?u32) anyerror!usize,
    write_all: *const fn (*anyopaque, []const u8, ?u32) anyerror!void,
    close: *const fn (*anyopaque) void,
    destroy: *const fn (*anyopaque) void,
};

/// Owned byte-stream connection. `from` adapts any pointer whose child type
/// implements read, writeAll, close, and deinit with the same signatures.
pub const Connection = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub fn from(pointer: anytype) Connection {
        const Pointer = @TypeOf(pointer);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Connection.from expects a single-item pointer");
        }
        const State = pointer_info.pointer.child;
        const Adapter = struct {
            fn adapterRead(
                context: *anyopaque,
                buffer: []u8,
                timeout_ms: ?u32,
            ) anyerror!usize {
                const state: *State = @ptrCast(@alignCast(context));
                return state.read(buffer, timeout_ms);
            }

            fn adapterWriteAll(
                context: *anyopaque,
                bytes: []const u8,
                timeout_ms: ?u32,
            ) anyerror!void {
                const state: *State = @ptrCast(@alignCast(context));
                return state.writeAll(bytes, timeout_ms);
            }

            fn adapterClose(context: *anyopaque) void {
                const state: *State = @ptrCast(@alignCast(context));
                state.close();
            }

            fn adapterDestroy(context: *anyopaque) void {
                const state: *State = @ptrCast(@alignCast(context));
                state.deinit();
            }

            const vtable: VTable = .{
                .read = adapterRead,
                .write_all = adapterWriteAll,
                .close = adapterClose,
                .destroy = adapterDestroy,
            };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn read(
        self: Connection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        return self.vtable.read(self.context, buffer, timeout_ms);
    }

    pub fn writeAll(
        self: Connection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        return self.vtable.write_all(self.context, bytes, timeout_ms);
    }

    pub fn close(self: Connection) void {
        self.vtable.close(self.context);
    }

    pub fn deinit(self: *Connection) void {
        self.vtable.destroy(self.context);
        self.* = undefined;
    }
};

const UnixConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    mutex: std.Thread.Mutex = .{},
    closed: bool = false,

    fn wait(self: *UnixConnection, events: i16, timeout_ms: ?u32) !void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.stream.handle,
            .events = events,
            .revents = 0,
        }};
        const timeout: i32 = if (timeout_ms) |milliseconds|
            @intCast(@min(milliseconds, @as(u32, std.math.maxInt(i32))))
        else
            -1;
        if (try std.posix.poll(&poll_fds, timeout) == 0) return error.Timeout;
        if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }
    }

    fn read(
        self: *UnixConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        try self.wait(std.posix.POLL.IN, timeout_ms);
        return self.stream.read(buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => error.ConnectionClosed,
            else => err,
        };
    }

    fn writeAll(
        self: *UnixConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            try self.wait(std.posix.POLL.OUT, timeout_ms);
            const written = self.stream.write(remaining) catch |err| switch (err) {
                error.BrokenPipe,
                error.ConnectionResetByPeer,
                error.SocketNotConnected,
                => return error.ConnectionClosed,
                else => return err,
            };
            if (written == 0) return error.ConnectionClosed;
            remaining = remaining[written..];
        }
    }

    fn close(self: *UnixConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        std.posix.shutdown(self.stream.handle, .both) catch {};
        self.stream.close();
    }

    fn deinit(self: *UnixConnection) void {
        const allocator = self.allocator;
        self.close();
        allocator.destroy(self);
    }
};

pub fn connectUnix(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Connection {
    const state = try allocator.create(UnixConnection);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .stream = try std.net.connectUnixSocket(path),
    };
    return Connection.from(state);
}

pub fn validateSession(session: []const u8) !void {
    if (session.len == 0 or session.len > 64) return error.InvalidSession;
    if (std.mem.eql(u8, session, ".") or std.mem.eql(u8, session, "..")) {
        return error.InvalidSession;
    }
    for (session, 0..) |byte, index| {
        const valid = std.ascii.isAlphanumeric(byte) or
            (index > 0 and (byte == '.' or byte == '_' or byte == '-'));
        if (!valid) return error.InvalidSession;
    }
}

fn environment(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

/// Resolves explicit path, CMUX_TUI_SOCKET, CMUX_MUX_SOCKET, then the
/// per-user runtime path under XDG_RUNTIME_DIR, TMPDIR, or /tmp.
pub fn resolveSocketPath(
    allocator: std.mem.Allocator,
    explicit: ?[]const u8,
    session: []const u8,
) ![]u8 {
    if (explicit) |path| {
        if (path.len == 0) return error.EmptySocketPath;
        return allocator.dupe(u8, path);
    }
    if (try environment(allocator, "CMUX_TUI_SOCKET")) |path| return path;
    if (try environment(allocator, "CMUX_MUX_SOCKET")) |path| return path;
    try validateSession(session);

    var owned_base: ?[]u8 = try environment(allocator, "XDG_RUNTIME_DIR");
    if (owned_base == null) {
        owned_base = try environment(allocator, "TMPDIR");
    }
    defer if (owned_base) |base| allocator.free(base);
    const base = owned_base orelse "/tmp";
    const preferred = try std.fmt.allocPrint(
        allocator,
        "{s}/cmux-tui-{d}/{s}.sock",
        .{ base, std.posix.getuid(), session },
    );
    if (preferred.len < 103) return preferred;
    allocator.free(preferred);
    return std.fmt.allocPrint(
        allocator,
        "/tmp/cmux-tui-{d}/{s}.sock",
        .{ std.posix.getuid(), session },
    );
}

test "session validation rejects path traversal" {
    try std.testing.expectError(error.InvalidSession, validateSession("../bad"));
    try std.testing.expectError(error.InvalidSession, validateSession(""));
    try validateSession("agent-1.dev");
}

test "explicit socket discovery wins" {
    const path = try resolveSocketPath(
        std.testing.allocator,
        "/tmp/explicit.sock",
        "main",
    );
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/explicit.sock", path);
}

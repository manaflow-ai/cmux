const std = @import("std");
const builtin = @import("builtin");
const transport_hook_test = if (builtin.is_test)
    @import("transport_hook_test.zig")
else
    struct {};

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

/// A connected transport and the owned path used to reach it.
pub const ResolvedConnection = struct {
    connection: Connection,
    path: []u8,
};

const Deadline = struct {
    timer: ?std.time.Timer = null,
    timeout_ns: u64 = 0,

    fn start(timeout_ms: ?u32) !Deadline {
        const milliseconds = timeout_ms orelse return .{};
        return .{
            .timer = try std.time.Timer.start(),
            .timeout_ns = @as(u64, milliseconds) * std.time.ns_per_ms,
        };
    }

    fn remainingMs(self: *Deadline) !?u32 {
        const timer = if (self.timer) |*value| value else return null;
        const elapsed_ns = timer.read();
        if (elapsed_ns >= self.timeout_ns) return error.Timeout;
        const remaining_ns = self.timeout_ns - elapsed_ns;
        return @intCast(
            (remaining_ns - 1) / std.time.ns_per_ms + 1,
        );
    }
};

const PollOnceError = std.posix.PollError || error{SignalInterrupt};

fn pollOnce(fds: []std.posix.pollfd, timeout: i32) PollOnceError!usize {
    if (builtin.os.tag == .windows) {
        return std.posix.poll(fds, timeout);
    } else {
        const fds_count = std.math.cast(std.posix.nfds_t, fds.len) orelse
            return error.SystemResources;
        const result = std.posix.system.poll(fds.ptr, fds_count, timeout);
        return switch (std.posix.errno(result)) {
            .SUCCESS => @intCast(result),
            .FAULT => unreachable,
            .INTR => error.SignalInterrupt,
            .INVAL => unreachable,
            .NOMEM => error.SystemResources,
            else => |failure| std.posix.unexpectedErrno(failure),
        };
    }
}

const UnixWaitTestHook = struct {
    entered_poll: std.Thread.ResetEvent = .{},
    returned_from_poll: std.Thread.ResetEvent = .{},
    continue_wait: std.Thread.ResetEvent = .{},
};

const UnixCloseTestHook = struct {
    shutdown_complete: std.Thread.ResetEvent = .{},
    continue_close: std.Thread.ResetEvent = .{},
};

const UnixConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    active_calls: usize = 0,
    closed: bool = false,
    fd_released: bool = false,
    test_wait_hook: if (builtin.is_test) ?*UnixWaitTestHook else void =
        if (builtin.is_test) null else {},
    test_close_hook: if (builtin.is_test) ?*UnixCloseTestHook else void =
        if (builtin.is_test) null else {},

    fn beginIo(self: *UnixConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.ConnectionClosed;
        self.active_calls += 1;
    }

    fn endIo(self: *UnixConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.active_calls > 0);
        self.active_calls -= 1;
        if (self.active_calls == 0) {
            self.releaseFdLocked();
            self.condition.broadcast();
        }
    }

    fn releaseFdLocked(self: *UnixConnection) void {
        if (!self.closed or self.active_calls != 0 or self.fd_released) return;
        self.fd_released = true;
        self.stream.close();
    }

    fn isClosed(self: *UnixConnection) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }

    fn wait(self: *UnixConnection, events: i16, timeout_ms: ?u32) !void {
        if (self.isClosed()) return error.ConnectionClosed;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.stream.handle,
            .events = events,
            .revents = 0,
        }};
        const timeout: i32 = if (timeout_ms) |milliseconds|
            @intCast(@min(milliseconds, @as(u32, std.math.maxInt(i32))))
        else
            -1;
        if (builtin.is_test) {
            if (self.test_wait_hook) |hook| hook.entered_poll.set();
        }
        const ready = try pollOnce(&poll_fds, timeout);
        if (builtin.is_test) {
            if (self.test_wait_hook) |hook| {
                hook.returned_from_poll.set();
                hook.continue_wait.wait();
            }
        }
        if (self.isClosed()) return error.ConnectionClosed;
        if (ready == 0) return error.Timeout;
        if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionClosed;
        }
    }

    fn read(
        self: *UnixConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        try self.beginIo();
        defer self.endIo();
        const count = readWithTimeout(self, buffer, timeout_ms) catch |failure| {
            if (self.isClosed()) return error.ConnectionClosed;
            return failure;
        };
        if (self.isClosed()) return error.ConnectionClosed;
        return count;
    }

    fn waitReadable(self: *UnixConnection, timeout_ms: ?u32) !void {
        return self.wait(std.posix.POLL.IN, timeout_ms);
    }

    fn readSome(self: *UnixConnection, buffer: []u8) !usize {
        return self.stream.read(buffer) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => error.ConnectionClosed,
            else => err,
        };
    }

    fn waitWritable(self: *UnixConnection, timeout_ms: ?u32) !void {
        return self.wait(std.posix.POLL.OUT, timeout_ms);
    }

    fn writeSome(self: *UnixConnection, bytes: []const u8) !usize {
        return self.stream.write(bytes) catch |err| switch (err) {
            error.BrokenPipe,
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
        try self.beginIo();
        defer self.endIo();
        writeAllWithTimeout(self, bytes, timeout_ms) catch |failure| {
            if (self.isClosed()) return error.ConnectionClosed;
            return failure;
        };
        if (self.isClosed()) return error.ConnectionClosed;
    }

    fn close(self: *UnixConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return;
        self.closed = true;
        // Wake active I/O, then release immediately if no lease can still
        // observe the descriptor. The final lease otherwise releases it.
        std.posix.shutdown(self.stream.handle, .both) catch {};
        if (builtin.is_test) {
            if (self.test_close_hook) |hook| {
                hook.shutdown_complete.set();
                hook.continue_close.wait();
            }
        }
        self.releaseFdLocked();
    }

    fn deinit(self: *UnixConnection) void {
        const allocator = self.allocator;
        self.close();
        self.mutex.lock();
        while (self.active_calls != 0) self.condition.wait(&self.mutex);
        self.releaseFdLocked();
        std.debug.assert(self.fd_released);
        self.mutex.unlock();
        allocator.destroy(self);
    }
};

fn readWithTimeout(
    state: anytype,
    buffer: []u8,
    timeout_ms: ?u32,
) !usize {
    var deadline = try Deadline.start(timeout_ms);
    while (true) {
        state.waitReadable(try deadline.remainingMs()) catch |failure| {
            if (failure == error.SignalInterrupt) continue;
            return failure;
        };
        return state.readSome(buffer) catch |failure| {
            if (failure == error.WouldBlock) continue;
            return failure;
        };
    }
}

fn writeAllWithTimeout(
    state: anytype,
    bytes: []const u8,
    timeout_ms: ?u32,
) !void {
    var deadline = try Deadline.start(timeout_ms);
    var remaining = bytes;
    while (remaining.len > 0) {
        state.waitWritable(try deadline.remainingMs()) catch |failure| {
            if (failure == error.SignalInterrupt) continue;
            return failure;
        };
        const written = state.writeSome(remaining) catch |failure| {
            if (failure == error.WouldBlock) continue;
            return failure;
        };
        if (written == 0) return error.ConnectionClosed;
        remaining = remaining[written..];
        _ = try deadline.remainingMs();
    }
}

pub fn connectUnix(
    allocator: std.mem.Allocator,
    path: []const u8,
) !Connection {
    return connectUnixWithTimeout(allocator, path, null);
}

pub fn connectUnixWithTimeout(
    allocator: std.mem.Allocator,
    path: []const u8,
    timeout_ms: ?u32,
) !Connection {
    const state = try allocator.create(UnixConnection);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
        .stream = try connectUnixStream(path, timeout_ms),
    };
    return Connection.from(state);
}

/// Connects an implicitly resolved socket, retrying the pre-hash /tmp raw
/// location for hashed paths. The retry is intentionally limited to the two
/// errors that mean the preferred endpoint is absent or stale.
pub fn connectResolvedWithLegacyFallback(
    allocator: std.mem.Allocator,
    path: []const u8,
    session: []const u8,
    timeout_ms: ?u32,
) !ResolvedConnection {
    var connection = connectUnixWithTimeout(allocator, path, timeout_ms) catch |failure| {
        if (failure != error.FileNotFound and failure != error.ConnectionRefused) return failure;
        if (!isHashedSocketPath(path)) return failure;
        const legacy = try sessionSocketPath(allocator, "/tmp", session);
        errdefer allocator.free(legacy);
        // A legacy session path can exceed the sockaddr_un limit even when
        // the hashed endpoint fits. Do not probe it in that case: the
        // resulting PathTooLong would mask the preferred endpoint failure.
        if (!unixSocketPathFits(legacy)) return failure;
        return .{ .connection = try connectUnixWithTimeout(allocator, legacy, timeout_ms), .path = legacy };
    };
    // Keep the socket owned by this function until the result path is also
    // allocated. If the duplicate fails, the connection must be released.
    errdefer connection.deinit();
    return .{ .connection = connection, .path = try allocator.dupe(u8, path) };
}

fn isHashedSocketPath(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    const component = std.fs.path.basename(parent);
    const prefix = "cmux-tui-hashed-";
    if (!std.mem.startsWith(u8, component, prefix)) return false;
    const uid_text = component[prefix.len..];
    if (uid_text.len == 0) return false;
    const uid = std.fmt.parseInt(u32, uid_text, 10) catch return false;
    return uid == std.posix.getuid();
}

fn connectUnixStream(
    path: []const u8,
    timeout_ms: ?u32,
) !std.net.Stream {
    var deadline = try Deadline.start(timeout_ms);
    const socket = try std.posix.socket(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM |
            std.posix.SOCK.CLOEXEC |
            std.posix.SOCK.NONBLOCK,
        0,
    );
    errdefer std.posix.close(socket);
    var address = try std.net.Address.initUnix(path);
    var pending = false;
    std.posix.connect(
        socket,
        &address.any,
        address.getOsSockLen(),
    ) catch |failure| switch (failure) {
        error.WouldBlock, error.ConnectionPending => pending = true,
        error.ConnectionTimedOut => return error.Timeout,
        else => return failure,
    };
    while (pending) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = socket,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        if (builtin.is_test) {
            if (transport_hook_test.connect_hook) |hook| {
                poll_fds[0].fd = hook.poll_fd_override orelse socket;
            }
        }
        const remaining_ms = try deadline.remainingMs();
        const poll_timeout: i32 = if (remaining_ms) |milliseconds|
            @intCast(@min(
                milliseconds,
                @as(u32, std.math.maxInt(i32)),
            ))
        else
            -1;
        if (builtin.is_test) {
            if (transport_hook_test.connect_hook) |hook| {
                hook.entered_poll.set();
            }
        }
        const ready = pollOnce(&poll_fds, poll_timeout) catch |failure| {
            if (failure == error.SignalInterrupt) continue;
            return failure;
        };
        if (builtin.is_test) {
            if (transport_hook_test.connect_hook) |hook| {
                hook.returned_from_poll.set();
                hook.continue_wait.wait();
                if (hook.fail_ready_poll and ready != 0) {
                    return error.TestPollReleased;
                }
            }
        }
        if (ready == 0) {
            return error.Timeout;
        }
        std.posix.getsockoptError(socket) catch |failure| switch (failure) {
            error.WouldBlock, error.ConnectionPending => continue,
            error.ConnectionTimedOut => return error.Timeout,
            else => return failure,
        };
        pending = false;
    }
    _ = try deadline.remainingMs();
    return .{ .handle = socket };
}

pub fn validateSession(session: []const u8) !void {
    if (session.len == 0 or
        std.mem.eql(u8, session, ".") or
        std.mem.eql(u8, session, ".."))
    {
        return error.InvalidSession;
    }
    var iterator = (std.unicode.Utf8View.init(session) catch {
        return error.InvalidSession;
    }).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == '/' or codepoint == '\\' or codepoint == 0 or
            codepoint <= 0x001F or
            (codepoint >= 0x007F and codepoint <= 0x009F) or
            codepoint == 0x0085 or
            codepoint == 0x2028 or
            codepoint == 0x2029)
        {
            return error.InvalidSession;
        }
    }
}

fn unixSocketPathFits(path: []const u8) bool {
    const capacity: usize = if (builtin.os.tag == .macos) 104 else 108;
    return path.len < capacity;
}

fn runtimeDirectoryPath(
    allocator: std.mem.Allocator,
    base_view: []const u8,
    directory: []const u8,
    leaf: []const u8,
) ![]u8 {
    const base = if (base_view.len == 0) "/tmp" else base_view;
    const separator: []const u8 = if (base[base.len - 1] == '/') "" else "/";
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}/{s}",
        .{ base, separator, directory, leaf },
    );
}

fn sessionSocketPath(
    allocator: std.mem.Allocator,
    base: []const u8,
    session: []const u8,
) ![]u8 {
    const directory = try std.fmt.allocPrint(
        allocator,
        "cmux-tui-{d}",
        .{std.posix.getuid()},
    );
    defer allocator.free(directory);
    const leaf = try std.fmt.allocPrint(allocator, "{s}.sock", .{session});
    defer allocator.free(leaf);
    return runtimeDirectoryPath(allocator, base, directory, leaf);
}

fn hashedSessionSocketPath(
    allocator: std.mem.Allocator,
    base: []const u8,
    session: []const u8,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const directory = try std.fmt.allocPrint(
        allocator,
        "cmux-tui-hashed-{d}",
        .{std.posix.getuid()},
    );
    defer allocator.free(directory);
    const leaf = try std.fmt.allocPrint(allocator, "{s}.sock", .{&hex});
    defer allocator.free(leaf);
    return runtimeDirectoryPath(allocator, base, directory, leaf);
}

fn environment(
    allocator: std.mem.Allocator,
    name: []const u8,
) !?[]u8 {
    const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

pub fn hasSocketOverride() !bool {
    for ([_][]const u8{ "CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET" }) |name| {
        const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => continue,
            else => return err,
        };
        defer std.heap.page_allocator.free(value);
        if (value.len != 0) return true;
    }
    return false;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |path| {
        if (path.len != 0) return path;
    }
    return null;
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

    const tui_socket = try environment(allocator, "CMUX_TUI_SOCKET");
    defer if (tui_socket) |path| allocator.free(path);
    const mux_socket = try environment(allocator, "CMUX_MUX_SOCKET");
    defer if (mux_socket) |path| allocator.free(path);
    const xdg_runtime_dir = try environment(allocator, "XDG_RUNTIME_DIR");
    defer if (xdg_runtime_dir) |path| allocator.free(path);
    const tmpdir = try environment(allocator, "TMPDIR");
    defer if (tmpdir) |path| allocator.free(path);

    return resolveSocketPathWithEnvironment(
        allocator,
        null,
        session,
        tui_socket,
        mux_socket,
        xdg_runtime_dir,
        tmpdir,
    );
}

fn resolveSocketPathWithEnvironment(
    allocator: std.mem.Allocator,
    explicit: ?[]const u8,
    session: []const u8,
    tui_socket: ?[]const u8,
    mux_socket: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    tmpdir: ?[]const u8,
) ![]u8 {
    if (explicit) |path| {
        if (path.len == 0) return error.EmptySocketPath;
        return allocator.dupe(u8, path);
    }
    if (nonEmpty(tui_socket)) |path| return allocator.dupe(u8, path);
    if (nonEmpty(mux_socket)) |path| return allocator.dupe(u8, path);
    try validateSession(session);

    const base = nonEmpty(xdg_runtime_dir) orelse nonEmpty(tmpdir) orelse "/tmp";
    const preferred = try sessionSocketPath(allocator, base, session);
    if (unixSocketPathFits(preferred)) return preferred;
    allocator.free(preferred);
    const fallback = try sessionSocketPath(allocator, "/tmp", session);
    if (unixSocketPathFits(fallback)) return fallback;
    allocator.free(fallback);
    var hashed = try hashedSessionSocketPath(allocator, base, session);
    if (unixSocketPathFits(hashed)) return hashed;
    allocator.free(hashed);
    hashed = try hashedSessionSocketPath(allocator, "/tmp", session);
    if (!unixSocketPathFits(hashed)) {
        allocator.free(hashed);
        return error.SocketPathTooLong;
    }
    return hashed;
}

test "session validation rejects path traversal" {
    for ([_][]const u8{
        "",
        ".",
        "..",
        "../bad",
        "nested/bad",
        "nested\\bad",
        "bad\x00name",
        "bad\nname",
        "bad\xed\xa0\x80name",
        "bad\xc2\x85name",
        "bad\xe2\x80\xa8name",
        "bad\xe2\x80\xa9name",
        "bad\xffname",
    }) |session| {
        try std.testing.expectError(error.InvalidSession, validateSession(session));
    }
}

test "session validation preserves legacy-safe names" {
    for ([_][]const u8{
        "agent-1.dev",
        "contains space",
        "名前",
        "_leading",
        "-leading",
        ".leading",
        "legacy:colon",
    }) |session| {
        try validateSession(session);
    }

    var long_name: [207]u8 = undefined;
    @memcpy(long_name[0..7], "legacy-");
    @memset(long_name[7..], 'x');
    try validateSession(&long_name);
}

test "long session socket path uses a bindable digest fallback" {
    var long_name: [207]u8 = undefined;
    @memcpy(long_name[0..7], "legacy-");
    @memset(long_name[7..], 'x');
    const path = try resolveSocketPathWithEnvironment(
        std.testing.allocator,
        null,
        &long_name,
        null,
        null,
        "/run/user/501",
        null,
    );
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/run/user/501/cmux-tui-hashed-{d}/e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",
        .{std.posix.getuid()},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
    _ = try std.net.Address.initUnix(path);
}

test "non-ASCII long session paths use the shared UTF-8 SHA-256 digest" {
    const pair = "\xE5\x90\x8D\xE5\x89\x8D";
    var session: [600]u8 = undefined;
    for (0..100) |index| {
        @memcpy(session[index * pair.len .. (index + 1) * pair.len], pair);
    }
    const path = try resolveSocketPathWithEnvironment(
        std.testing.allocator,
        null,
        &session,
        null,
        null,
        "/run/user/501",
        null,
    );
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/run/user/501/cmux-tui-hashed-{d}/0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3.sock",
        .{std.posix.getuid()},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "hashed session socket path falls back to slash tmp when runtime base is too long" {
    var long_base: [220]u8 = undefined;
    @memcpy(long_base[0..5], "/tmp/");
    @memset(long_base[5..], 'x');
    var long_name: [207]u8 = undefined;
    @memcpy(long_name[0..7], "legacy-");
    @memset(long_name[7..], 'x');
    const path = try resolveSocketPathWithEnvironment(
        std.testing.allocator,
        null,
        &long_name,
        null,
        null,
        &long_base,
        null,
    );
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/cmux-tui-hashed-{d}/e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock",
        .{std.posix.getuid()},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}

test "legacy fallback path is rejected before connect when session is too long" {
    var long_name: [207]u8 = undefined;
    @memcpy(long_name[0..7], "legacy-");
    @memset(long_name[7..], 'x');
    const legacy = try sessionSocketPath(std.testing.allocator, "/tmp", &long_name);
    defer std.testing.allocator.free(legacy);
    try std.testing.expect(!unixSocketPathFits(legacy));
}

test "hashed socket detection ignores marker in runtime directory" {
    try std.testing.expect(!isHashedSocketPath(
        "/tmp/cmux-tui-hashed-marker/cmux-tui-501/main.sock",
    ));
}

test "empty inherited socket values are ignored" {
    const path = try resolveSocketPathWithEnvironment(
        std.testing.allocator,
        null,
        "main",
        "",
        "",
        "/runtime",
        null,
    );
    defer std.testing.allocator.free(path);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "/runtime/cmux-tui-{d}/main.sock",
        .{std.posix.getuid()},
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
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

test "partial Unix writes share one absolute timeout" {
    const SlowWriter = struct {
        wait_calls: usize = 0,

        fn waitWritable(self: *@This(), timeout_ms: ?u32) !void {
            self.wait_calls += 1;
            const delay_ms: u32 = 8;
            if (timeout_ms) |remaining_ms| {
                if (remaining_ms <= delay_ms) {
                    std.Thread.sleep(
                        @as(u64, remaining_ms) * std.time.ns_per_ms,
                    );
                    return error.Timeout;
                }
            }
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }

        fn writeSome(_: *@This(), bytes: []const u8) !usize {
            return @min(bytes.len, 1);
        }
    };
    var writer = SlowWriter{};

    try std.testing.expectError(
        error.Timeout,
        writeAllWithTimeout(&writer, "four", 20),
    );
    try std.testing.expect(writer.wait_calls >= 2);
}

test "read retries readiness races instead of surfacing WouldBlock" {
    const RacingReader = struct {
        wait_calls: usize = 0,
        read_calls: usize = 0,

        fn waitReadable(self: *@This(), timeout_ms: ?u32) !void {
            _ = timeout_ms;
            self.wait_calls += 1;
        }

        fn readSome(self: *@This(), buffer: []u8) !usize {
            self.read_calls += 1;
            if (self.read_calls == 1) return error.WouldBlock;
            buffer[0] = 'x';
            return 1;
        }
    };
    var reader = RacingReader{};
    var buffer: [1]u8 = undefined;

    try std.testing.expectEqual(
        @as(usize, 1),
        try readWithTimeout(&reader, &buffer, 20),
    );
    try std.testing.expectEqual(@as(usize, 2), reader.wait_calls);
    try std.testing.expectEqual(@as(usize, 2), reader.read_calls);
    try std.testing.expectEqual(@as(u8, 'x'), buffer[0]);
}

fn testSignalHandler(_: i32) callconv(.c) void {}

fn installTestSignalHandler() std.posix.Sigaction {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = testSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.USR1, &action, &previous);
    return previous;
}

fn interruptTestThread(thread_id: std.Thread.Id) !bool {
    const result = std.os.linux.tkill(
        @intCast(thread_id),
        std.posix.SIG.USR1,
    );
    return switch (std.posix.errno(result)) {
        .SUCCESS => true,
        .SRCH => false,
        else => |failure| std.posix.unexpectedErrno(failure),
    };
}

fn interruptTestThreadUntilExit(thread_id: std.Thread.Id) !usize {
    var delivered: usize = 0;
    for (0..20) |_| {
        std.Thread.sleep(5 * std.time.ns_per_ms);
        if (!try interruptTestThread(thread_id)) break;
        delivered += 1;
    }
    return delivered;
}

fn expectInterruptedDeadline(
    failure: ?anyerror,
    elapsed_ns: u64,
    delivered: usize,
) !void {
    try std.testing.expectEqual(
        error.Timeout,
        failure orelse return error.ExpectedTimeout,
    );
    try std.testing.expect(elapsed_ns < 70 * std.time.ns_per_ms);
    try std.testing.expect(delivered >= 2);
}

test "Unix read deadline survives repeated signal interruptions" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const previous_action = installTestSignalHandler();
    defer std.posix.sigaction(
        std.posix.SIG.USR1,
        &previous_action,
        null,
    );

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/interrupted-read.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var connection = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer connection.deinit();
    const peer = try server.accept();
    defer peer.stream.close();

    const state: *UnixConnection = @ptrCast(@alignCast(connection.context));
    var hook = UnixWaitTestHook{};
    hook.continue_wait.set();
    state.test_wait_hook = &hook;
    const PendingRead = struct {
        connection: *Connection,
        thread_id: std.Thread.Id = 0,
        id_ready: std.Thread.ResetEvent = .{},
        failure: ?anyerror = null,
        elapsed_ns: u64 = 0,

        fn run(self: *@This()) void {
            self.thread_id = std.Thread.getCurrentId();
            self.id_ready.set();
            var timer = std.time.Timer.start() catch |failure| {
                self.failure = failure;
                return;
            };
            var bytes: [1]u8 = undefined;
            _ = self.connection.read(&bytes, 20) catch |failure| {
                self.failure = failure;
                self.elapsed_ns = timer.read();
                return;
            };
            self.elapsed_ns = timer.read();
        }
    };
    var pending = PendingRead{ .connection = &connection };
    const thread = try std.Thread.spawn(.{}, PendingRead.run, .{&pending});
    var joined = false;
    defer if (!joined) thread.join();
    try pending.id_ready.timedWait(std.time.ns_per_s);
    try hook.entered_poll.timedWait(std.time.ns_per_s);
    const delivered = try interruptTestThreadUntilExit(pending.thread_id);
    thread.join();
    joined = true;

    try expectInterruptedDeadline(
        pending.failure,
        pending.elapsed_ns,
        delivered,
    );
}

test "Unix write deadline survives repeated signal interruptions" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const previous_action = installTestSignalHandler();
    defer std.posix.sigaction(
        std.posix.SIG.USR1,
        &previous_action,
        null,
    );

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/interrupted-write.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var connection = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer connection.deinit();
    const peer = try server.accept();
    defer peer.stream.close();

    const state: *UnixConnection = @ptrCast(@alignCast(connection.context));
    var buffer_size: c_int = 4 * 1024;
    try std.posix.setsockopt(
        state.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&buffer_size),
    );
    try std.posix.setsockopt(
        peer.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&buffer_size),
    );
    var fill: [64 * 1024]u8 = undefined;
    @memset(&fill, 0x5a);
    while (true) {
        _ = state.stream.write(&fill) catch |failure| switch (failure) {
            error.WouldBlock => break,
            else => return failure,
        };
    }

    var hook = UnixWaitTestHook{};
    hook.continue_wait.set();
    state.test_wait_hook = &hook;
    const PendingWrite = struct {
        connection: *Connection,
        thread_id: std.Thread.Id = 0,
        id_ready: std.Thread.ResetEvent = .{},
        failure: ?anyerror = null,
        elapsed_ns: u64 = 0,

        fn run(self: *@This()) void {
            self.thread_id = std.Thread.getCurrentId();
            self.id_ready.set();
            var timer = std.time.Timer.start() catch |failure| {
                self.failure = failure;
                return;
            };
            self.connection.writeAll("x", 20) catch |failure| {
                self.failure = failure;
                self.elapsed_ns = timer.read();
                return;
            };
            self.elapsed_ns = timer.read();
        }
    };
    var pending = PendingWrite{ .connection = &connection };
    const thread = try std.Thread.spawn(.{}, PendingWrite.run, .{&pending});
    var joined = false;
    defer if (!joined) thread.join();
    try pending.id_ready.timedWait(std.time.ns_per_s);
    try hook.entered_poll.timedWait(std.time.ns_per_s);
    const delivered = try interruptTestThreadUntilExit(pending.thread_id);
    thread.join();
    joined = true;

    try expectInterruptedDeadline(
        pending.failure,
        pending.elapsed_ns,
        delivered,
    );
}

test "connect deadline survives repeated signal interruptions" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const previous_action = installTestSignalHandler();
    defer std.posix.sigaction(
        std.posix.SIG.USR1,
        &previous_action,
        null,
    );

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/interrupted-connect.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{ .kernel_backlog = 0 });
    defer server.deinit();
    const blocker = try connectUnixStream(path, 1_000);
    defer blocker.close();

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
    };
    hook.continue_wait.set();
    transport_hook_test.connect_hook = &hook;
    defer transport_hook_test.connect_hook = null;
    const PendingConnect = struct {
        path: []const u8,
        thread_id: std.Thread.Id = 0,
        id_ready: std.Thread.ResetEvent = .{},
        stream: ?std.net.Stream = null,
        failure: ?anyerror = null,
        elapsed_ns: u64 = 0,

        fn run(self: *@This()) void {
            self.thread_id = std.Thread.getCurrentId();
            self.id_ready.set();
            var timer = std.time.Timer.start() catch |failure| {
                self.failure = failure;
                return;
            };
            self.stream = connectUnixStream(self.path, 20) catch |failure| {
                self.failure = failure;
                self.elapsed_ns = timer.read();
                return;
            };
            self.elapsed_ns = timer.read();
        }
    };
    var pending = PendingConnect{ .path = path };
    const thread = try std.Thread.spawn(.{}, PendingConnect.run, .{&pending});
    var joined = false;
    defer if (!joined) thread.join();
    try pending.id_ready.timedWait(std.time.ns_per_s);
    try hook.entered_poll.timedWait(std.time.ns_per_s);
    const delivered = try interruptTestThreadUntilExit(pending.thread_id);
    thread.join();
    joined = true;
    defer if (pending.stream) |stream| stream.close();

    try expectInterruptedDeadline(
        pending.failure,
        pending.elapsed_ns,
        delivered,
    );
}

test "large Unix write to a nonreading peer honors its deadline" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/nonreading.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var connection = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer connection.deinit();
    const peer = try server.accept();
    defer peer.stream.close();
    const state: *UnixConnection = @ptrCast(@alignCast(connection.context));
    var buffer_size: c_int = 4 * 1024;
    try std.posix.setsockopt(
        state.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&buffer_size),
    );
    try std.posix.setsockopt(
        peer.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&buffer_size),
    );

    const Helpers = struct {
        fn setNonblocking(fd: std.posix.fd_t, enabled: bool) !void {
            var flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
            const nonblocking = @as(usize, 1) <<
                @bitOffsetOf(std.posix.O, "NONBLOCK");
            if (enabled) {
                flags |= nonblocking;
            } else {
                flags &= ~nonblocking;
            }
            _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags);
        }
    };
    const original_flags = try std.posix.fcntl(
        state.stream.handle,
        std.posix.F.GETFL,
        0,
    );
    try Helpers.setNonblocking(state.stream.handle, true);
    var fill: [64 * 1024]u8 = undefined;
    @memset(&fill, 0x5a);
    while (true) {
        _ = state.stream.write(&fill) catch |failure| switch (failure) {
            error.WouldBlock => break,
            else => return failure,
        };
    }
    _ = try std.posix.fcntl(
        state.stream.handle,
        std.posix.F.SETFL,
        original_flags,
    );

    const PeerDrain = struct {
        stream: std.net.Stream,
        failure: ?anyerror = null,
        read_bytes: usize = 0,

        fn run(self: *@This()) void {
            std.Thread.sleep(5 * std.time.ns_per_ms);
            var bytes: [64 * 1024]u8 = undefined;
            self.read_bytes = self.stream.read(&bytes) catch |failure| {
                self.failure = failure;
                return;
            };
        }
    };
    var peer_drain = PeerDrain{ .stream = peer.stream };
    const peer_thread = try std.Thread.spawn(
        .{},
        PeerDrain.run,
        .{&peer_drain},
    );
    var write_done = std.Thread.ResetEvent{};
    const Watchdog = struct {
        connection: *UnixConnection,
        done: *std.Thread.ResetEvent,

        fn run(self: @This()) void {
            self.done.timedWait(250 * std.time.ns_per_ms) catch {
                self.connection.close();
            };
        }
    };
    const watchdog = try std.Thread.spawn(
        .{},
        Watchdog.run,
        .{Watchdog{ .connection = state, .done = &write_done }},
    );
    const payload = try std.testing.allocator.alloc(u8, 8 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x78);
    var timer = try std.time.Timer.start();
    const write_failure: ?anyerror = blk: {
        connection.writeAll(payload, 20) catch |failure| {
            break :blk failure;
        };
        break :blk null;
    };
    const elapsed_ns = timer.read();
    write_done.set();
    peer_thread.join();
    watchdog.join();

    if (peer_drain.failure) |failure| return failure;
    try std.testing.expect(peer_drain.read_bytes > 0);
    try std.testing.expectEqual(
        error.Timeout,
        write_failure orelse return error.ExpectedTimeout,
    );
    try std.testing.expect(elapsed_ns < 100 * std.time.ns_per_ms);
}

test "idle Unix close releases its descriptor before deinit" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/idle-close.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var connection = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer connection.deinit();
    const peer = try server.accept();
    defer peer.stream.close();
    const state: *UnixConnection = @ptrCast(@alignCast(connection.context));
    const original_fd = state.stream.handle;

    connection.close();
    try std.testing.expect(state.fd_released);
    const reuse_probe = try std.posix.pipe();
    defer std.posix.close(reuse_probe[0]);
    defer std.posix.close(reuse_probe[1]);
    try std.testing.expect(
        reuse_probe[0] == original_fd or reuse_probe[1] == original_fd,
    );
}

test "closed Unix reconnect cycles reuse descriptors without double close" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/reconnect-close.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();

    const cycle_count = 16;
    var retired: [cycle_count]Connection = undefined;
    var retired_count: usize = 0;
    var retired_cleaned = false;
    defer if (!retired_cleaned) {
        for (retired[0..retired_count]) |*item| item.deinit();
    };
    var reused_fd: ?std.posix.fd_t = null;
    for (0..cycle_count) |_| {
        var connection = try connectUnixWithTimeout(
            std.testing.allocator,
            path,
            1_000,
        );
        var connection_owned = true;
        defer if (connection_owned) connection.deinit();
        const peer = try server.accept();
        defer peer.stream.close();
        const state: *UnixConnection = @ptrCast(
            @alignCast(connection.context),
        );
        if (reused_fd) |expected| {
            try std.testing.expectEqual(expected, state.stream.handle);
        } else {
            reused_fd = state.stream.handle;
        }
        connection.close();
        try std.testing.expect(state.fd_released);
        retired[retired_count] = connection;
        retired_count += 1;
        connection_owned = false;
    }

    var live = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    defer live.deinit();
    const live_peer = try server.accept();
    defer live_peer.stream.close();
    const live_state: *UnixConnection = @ptrCast(@alignCast(live.context));
    try std.testing.expectEqual(reused_fd.?, live_state.stream.handle);

    for (retired[0..retired_count]) |*item| item.deinit();
    retired_cleaned = true;
    const payload = "still-open";
    try std.testing.expectEqual(
        payload.len,
        try std.posix.write(live_peer.stream.handle, payload),
    );
    var received: [payload.len]u8 = undefined;
    try std.testing.expectEqual(
        payload.len,
        try live.read(&received, 1_000),
    );
    try std.testing.expectEqualSlices(u8, payload, &received);
}

test "closing a pending Unix read cannot consume a reused descriptor" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/close-read.sock",
        .{&temp.sub_path},
    );
    defer std.testing.allocator.free(path);
    const address = try std.net.Address.initUnix(path);
    var server = try address.listen(.{});
    defer server.deinit();
    var connection = try connectUnixWithTimeout(
        std.testing.allocator,
        path,
        1_000,
    );
    var connection_live = true;
    defer if (connection_live) connection.deinit();
    const peer = try server.accept();
    defer peer.stream.close();

    const state: *UnixConnection = @ptrCast(@alignCast(connection.context));
    const original_fd = state.stream.handle;
    var hook = UnixWaitTestHook{};
    state.test_wait_hook = &hook;
    var close_hook = UnixCloseTestHook{};
    state.test_close_hook = &close_hook;

    const PendingRead = struct {
        connection: *Connection,
        bytes: [32]u8 = undefined,
        count: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.count = self.connection.read(&self.bytes, null) catch |failure| {
                self.failure = failure;
                return;
            };
        }
    };
    var pending = PendingRead{ .connection = &connection };
    const read_thread = try std.Thread.spawn(.{}, PendingRead.run, .{&pending});
    var read_joined = false;
    defer if (!read_joined) {
        hook.continue_wait.set();
        read_thread.join();
    };

    try hook.entered_poll.timedWait(std.time.ns_per_s);
    const Closer = struct {
        connection: *Connection,

        fn run(self: @This()) void {
            self.connection.close();
        }
    };
    const close_thread = try std.Thread.spawn(
        .{},
        Closer.run,
        .{Closer{ .connection = &connection }},
    );
    var close_joined = false;
    defer if (!close_joined) {
        close_hook.continue_close.set();
        close_thread.join();
    };
    try close_hook.shutdown_complete.timedWait(std.time.ns_per_s);
    try hook.returned_from_poll.timedWait(std.time.ns_per_s);
    close_hook.continue_close.set();
    close_thread.join();
    close_joined = true;
    connection.close();
    try std.testing.expect(!state.fd_released);

    var reused_reader: ?std.posix.fd_t = null;
    var reused_writer: ?std.posix.fd_t = null;
    defer {
        if (reused_reader) |fd| std.posix.close(fd);
        if (reused_writer) |fd| std.posix.close(fd);
    }
    const pipe_fds = try std.posix.pipe();
    if (pipe_fds[0] == original_fd) {
        reused_reader = pipe_fds[0];
        reused_writer = pipe_fds[1];
    } else if (pipe_fds[1] == original_fd) {
        const writer_copy = try std.posix.dup(pipe_fds[1]);
        errdefer std.posix.close(writer_copy);
        try std.posix.dup2(pipe_fds[0], original_fd);
        std.posix.close(pipe_fds[0]);
        reused_reader = original_fd;
        reused_writer = writer_copy;
    } else {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
    }
    try std.testing.expect(reused_reader == null);
    if (reused_writer) |fd| {
        const marker = "unrelated-descriptor";
        try std.testing.expectEqual(marker.len, try std.posix.write(fd, marker));
    }

    hook.continue_wait.set();
    read_thread.join();
    read_joined = true;

    const failure = pending.failure orelse return error.ReadUnrelatedDescriptor;
    try std.testing.expectEqual(error.ConnectionClosed, failure);
    try std.testing.expectEqual(@as(usize, 0), pending.count);
    try std.testing.expect(state.fd_released);

    connection.deinit();
    connection_live = false;
    const released_probe = try std.posix.pipe();
    defer std.posix.close(released_probe[0]);
    defer std.posix.close(released_probe[1]);
    try std.testing.expect(
        released_probe[0] == original_fd or released_probe[1] == original_fd,
    );
}

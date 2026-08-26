const std = @import("std");

pub const ConnectHook = struct {
    entered_poll: std.Thread.ResetEvent = .{},
    returned_from_poll: std.Thread.ResetEvent = .{},
    continue_wait: std.Thread.ResetEvent = .{},
    poll_fd_override: ?std.posix.fd_t = null,
    fail_ready_poll: bool = false,
};

pub var connect_hook: ?*ConnectHook = null;

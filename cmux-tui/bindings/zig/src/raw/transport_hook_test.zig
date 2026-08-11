const std = @import("std");

pub const ConnectHook = struct {
    entered_poll: std.Io.Event = .unset,
    returned_from_poll: std.Io.Event = .unset,
    continue_wait: std.Io.Event = .unset,
    poll_fd_override: ?std.posix.fd_t = null,
    fail_ready_poll: bool = false,
};

pub var connect_hook: ?*ConnectHook = null;

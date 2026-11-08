const std = @import("std");
const cmux = @import("cmux_tui");

pub const ConnectOptions = struct {
    socket_path: []const u8,
    machine_name: []const u8,
    session_name: []const u8,
    workspace_name: []const u8,
    timeout_ms: ?u32 = 10_000,
};

pub const CreationKeys = [2][]const u8;

pub const WorkspaceReady = struct {
    id: cmux.WorkspaceId,
    revision: u64,
    created: bool,
    recovered: bool,
    replayed: bool,
};

pub const RunReceipt = struct {
    path: cmux.CreatedTerminalPath,
    revision: u64,
    recovered: bool,
    replayed: bool,
};

pub const ExitOutcome = union(enum) {
    exit: i32,
    signal: struct {
        signal: i32,
        core_dumped: bool,
    },
    unknown,
};

pub const PendingExit = struct {
    lifecycle: cmux.TerminalLifecycle,
    revision: u64,
};

pub const ExitedTerminal = struct {
    outcome: ExitOutcome,
    exited_at: u64,
    revision: u64,
};

pub const ExitObservation = union(enum) {
    pending: PendingExit,
    exited: ExitedTerminal,
};

pub const EventKind = enum {
    snapshot,
    delta,
    unknown,
};

pub const EventObservation = struct {
    kind: EventKind,
    sequence: u64,
    cursor_revision: ?u64,
    canceled_at_revision: ?u64,
};

const Resolution = union(enum) {
    created: struct {
        path: cmux.CreatedPath,
        revision: u64,
    },
    retry_same,
    retry_new,
};

pub const SessionSupervisor = struct {
    allocator: std.mem.Allocator,
    client: cmux.Client,
    machine_id: cmux.MachineId,
    session_id: cmux.SessionId,
    workspace_id: ?cmux.WorkspaceId,
    workspace_name: []u8,
    revision: u64,

    pub fn connect(
        allocator: std.mem.Allocator,
        options: ConnectOptions,
    ) !SessionSupervisor {
        var client = try cmux.Client.connect(allocator, .{
            .socket_path = options.socket_path,
            .timeout_ms = options.timeout_ms,
        });
        errdefer client.deinit();

        var machines = try client.listMachines();
        defer machines.deinit();
        const machine = try uniqueMachine(machines.items, options.machine_name);
        if (machine.deleted or !machine.connectable) {
            return error.MachineUnavailable;
        }

        var sessions = try client.machine(machine.id).listSessions();
        defer sessions.deinit();
        const session_snapshot = try uniqueSession(
            sessions.items,
            options.session_name,
        );
        if (!session_snapshot.connected) return error.SessionDisconnected;

        var workspaces = try client
            .machine(machine.id)
            .session(session_snapshot.id)
            .listWorkspaces();
        defer workspaces.deinit();
        const workspace_id = try optionalUniqueWorkspace(
            workspaces.items,
            options.workspace_name,
        );
        const workspace_name = try allocator.dupe(
            u8,
            options.workspace_name,
        );
        errdefer allocator.free(workspace_name);

        return .{
            .allocator = allocator,
            .client = client,
            .machine_id = machine.id,
            .session_id = session_snapshot.id,
            .workspace_id = workspace_id,
            .workspace_name = workspace_name,
            .revision = session_snapshot.revision,
        };
    }

    pub fn deinit(self: *SessionSupervisor) void {
        self.client.deinit();
        self.allocator.free(self.workspace_name);
        self.* = undefined;
    }

    pub fn ensureWorkspace(
        self: *SessionSupervisor,
        correlation_key: []const u8,
        idempotency_keys: CreationKeys,
    ) !WorkspaceReady {
        if (self.workspace_id) |workspace_id| {
            return .{
                .id = workspace_id,
                .revision = self.revision,
                .created = false,
                .recovered = false,
                .replayed = false,
            };
        }

        var attempt: usize = 0;
        var key_index: usize = 0;
        while (attempt < idempotency_keys.len) : (attempt += 1) {
            var result = self.session().createWorkspace(
                .{
                    .name = self.workspace_name,
                    .initial_content = .empty,
                    .correlation_key = correlation_key,
                },
                try cmux.MutationOptions.withKey(
                    idempotency_keys[key_index],
                ),
            ) catch |failure| {
                if (!self.shouldResolve(failure, .workspace_create)) {
                    return failure;
                }
                switch (try self.resolveCreation(
                    correlation_key,
                    .workspace_create,
                )) {
                    .created => |resolved| {
                        const workspace_id = switch (resolved.path) {
                            .workspace => |path| path.workspace_id,
                            else => return error.CreationPathMismatch,
                        };
                        try self.observeRevision(resolved.revision);
                        self.workspace_id = workspace_id;
                        return .{
                            .id = workspace_id,
                            .revision = resolved.revision,
                            .created = true,
                            .recovered = true,
                            .replayed = false,
                        };
                    },
                    .retry_same => continue,
                    .retry_new => {
                        key_index = 1;
                        continue;
                    },
                }
            };
            defer result.deinit();
            const workspace_id = switch (result.value) {
                .workspace => |path| path.workspace_id,
                else => return error.CreationPathMismatch,
            };
            try self.observeRevision(result.revision);
            self.workspace_id = workspace_id;
            return .{
                .id = workspace_id,
                .revision = result.revision,
                .created = true,
                .recovered = false,
                .replayed = result.replayed,
            };
        }
        return error.CreationRetryExhausted;
    }

    pub fn runExact(
        self: *SessionSupervisor,
        argv: []const []const u8,
        correlation_key: []const u8,
        idempotency_keys: CreationKeys,
    ) !RunReceipt {
        const workspace_id = self.workspace_id orelse
            return error.WorkspaceNotReady;
        var attempt: usize = 0;
        var key_index: usize = 0;
        while (attempt < idempotency_keys.len) : (attempt += 1) {
            var result = self.workspace(workspace_id).run(
                .{
                    .command = try cmux.RunCommand.argv(argv),
                    .correlation_key = correlation_key,
                },
                try self.revisionMutation(idempotency_keys[key_index]),
            ) catch |failure| {
                if (!self.shouldResolve(failure, .workspace_run)) {
                    return failure;
                }
                switch (try self.resolveCreation(
                    correlation_key,
                    .workspace_run,
                )) {
                    .created => |resolved| {
                        const path = switch (resolved.path) {
                            .terminal => |path| path,
                            else => return error.CreationPathMismatch,
                        };
                        if (!std.meta.eql(path.workspace_id, workspace_id)) {
                            return error.CreationPathMismatch;
                        }
                        try self.observeRevision(resolved.revision);
                        return .{
                            .path = path,
                            .revision = resolved.revision,
                            .recovered = true,
                            .replayed = false,
                        };
                    },
                    .retry_same => continue,
                    .retry_new => {
                        key_index = 1;
                        continue;
                    },
                }
            };
            defer result.deinit();
            if (!std.meta.eql(result.value.workspace_id, workspace_id)) {
                return error.CreationPathMismatch;
            }
            try self.observeRevision(result.revision);
            return .{
                .path = result.value,
                .revision = result.revision,
                .recovered = false,
                .replayed = result.replayed,
            };
        }
        return error.CreationRetryExhausted;
    }

    pub fn waitForExit(
        self: *SessionSupervisor,
        terminal_id: cmux.TerminalId,
        timeout_ms: ?u64,
    ) !ExitObservation {
        var result = try self
            .session()
            .terminal(terminal_id)
            .waitForExit(timeout_ms);
        defer result.deinit();
        return switch (result.value) {
            .pending => |pending| blk: {
                if (!std.meta.eql(pending.terminal_id, terminal_id)) {
                    return error.TerminalPathMismatch;
                }
                self.revision = @max(self.revision, pending.revision);
                break :blk .{ .pending = .{
                    .lifecycle = pending.lifecycle,
                    .revision = pending.revision,
                } };
            },
            .exited => |exited| blk: {
                if (!std.meta.eql(exited.terminal_id, terminal_id)) {
                    return error.TerminalPathMismatch;
                }
                self.revision = @max(self.revision, exited.revision);
                const outcome: ExitOutcome = switch (exited.outcome) {
                    .exit => |status| .{ .exit = status },
                    .signal => |signal| .{ .signal = .{
                        .signal = signal.signal,
                        .core_dumped = signal.core_dumped,
                    } },
                    .unknown => .unknown,
                };
                break :blk .{ .exited = .{
                    .outcome = outcome,
                    .exited_at = exited.exited_at,
                    .revision = exited.revision,
                } };
            },
        };
    }

    /// Polls durable terminal state so each socket read stays bounded.
    pub fn waitUntilExit(
        self: *SessionSupervisor,
        terminal_id: cmux.TerminalId,
        poll_timeout_ms: u64,
    ) !ExitedTerminal {
        if (poll_timeout_ms == 0) return error.InvalidWaitPoll;
        while (true) {
            switch (try self.waitForExit(
                terminal_id,
                poll_timeout_ms,
            )) {
                .pending => {},
                .exited => |exited| return exited,
            }
        }
    }

    /// Open and cancellation use the client's request timeout. After the open
    /// acknowledgement, `next` waits without a deadline for an ordinary idle
    /// stream event.
    pub fn observeOneEvent(
        self: *SessionSupervisor,
    ) !EventObservation {
        var stream = try self.session().events();
        defer stream.deinit();
        var item = (try stream.next()) orelse
            return error.StreamEndedBeforeItem;
        defer item.deinit();

        const kind: EventKind = switch (item.value) {
            .snapshot => .snapshot,
            .delta => .delta,
            .unknown => .unknown,
        };
        const cursor_revision = if (item.cursor) |cursor|
            cursor.revision
        else
            null;
        if (cursor_revision) |revision| {
            self.revision = @max(self.revision, revision);
        }
        const end = try stream.cancel();
        if (end.reason != .canceled) return error.StreamNotCanceled;
        const canceled_at_revision = if (end.cursor) |cursor|
            cursor.revision
        else
            null;
        return .{
            .kind = kind,
            .sequence = item.sequence,
            .cursor_revision = cursor_revision,
            .canceled_at_revision = canceled_at_revision,
        };
    }

    pub fn currentRevision(self: *const SessionSupervisor) u64 {
        return self.revision;
    }

    pub fn lastResourceError(
        self: *const SessionSupervisor,
    ) ?cmux.ResourceError {
        return self.client.lastResourceError();
    }

    fn session(self: *SessionSupervisor) cmux.Session {
        return self.client
            .machine(self.machine_id)
            .session(self.session_id);
    }

    fn workspace(
        self: *SessionSupervisor,
        workspace_id: cmux.WorkspaceId,
    ) cmux.Workspace {
        return self.session().workspace(workspace_id);
    }

    fn revisionMutation(
        self: *const SessionSupervisor,
        idempotency_key: []const u8,
    ) !cmux.MutationOptions {
        return (try cmux.MutationOptions.withKey(
            idempotency_key,
        )).expecting(self.revision);
    }

    fn observeRevision(
        self: *SessionSupervisor,
        revision: u64,
    ) !void {
        if (revision < self.revision) return error.RevisionRegressed;
        self.revision = revision;
    }

    fn shouldResolve(
        self: *const SessionSupervisor,
        failure: anyerror,
        operation: cmux.Operation,
    ) bool {
        if (failure == error.MutationTransportUncertain) {
            const uncertain =
                self.client.lastMutationTransportUncertain() orelse
                return false;
            return uncertain.operation == operation;
        }
        if (failure != error.RemoteError) return false;
        const remote = self.client.lastResourceError() orelse return false;
        if (!std.mem.eql(u8, remote.code, "mutation.indeterminate")) {
            return false;
        }
        return switch (remote.details) {
            .mutation_indeterminate => |details| std.mem.eql(
                u8,
                details.operation,
                operation.wireName(),
            ),
            else => false,
        };
    }

    fn resolveCreation(
        self: *SessionSupervisor,
        correlation_key: []const u8,
        operation: cmux.Operation,
    ) !Resolution {
        var result = try self.session().resolveCreation(correlation_key);
        defer result.deinit();
        const value = result.value;
        if (!std.mem.eql(u8, value.correlation_key, correlation_key)) {
            return error.CreationResolutionMismatch;
        }
        if (value.operation) |resolved_operation| {
            if (!std.mem.eql(
                u8,
                resolved_operation,
                operation.wireName(),
            )) {
                return error.CreationResolutionMismatch;
            }
        }
        return switch (value.state) {
            .created => .{ .created = .{
                .path = value.created_path orelse
                    return error.CreationResolutionIncomplete,
                .revision = value.revision orelse
                    return error.CreationResolutionIncomplete,
            } },
            .not_applied => switch (value.recovery) {
                .retry_same_idempotency_key => .retry_same,
                .retry_new_idempotency_key => .retry_new,
                else => error.CreationResolutionMismatch,
            },
            .pending => error.CreationPending,
            .indeterminate => error.CreationIndeterminate,
            .unknown => error.UnknownCreationState,
        };
    }
};

fn uniqueMachine(
    machines: []const cmux.MachineSnapshot,
    name: []const u8,
) !cmux.MachineSnapshot {
    var found: ?cmux.MachineSnapshot = null;
    for (machines) |machine| {
        if (!std.mem.eql(u8, machine.name, name)) continue;
        if (found != null) return error.AmbiguousMachineName;
        found = machine;
    }
    return found orelse error.MachineNotFound;
}

fn uniqueSession(
    sessions: []const cmux.SessionSnapshot,
    name: []const u8,
) !cmux.SessionSnapshot {
    var found: ?cmux.SessionSnapshot = null;
    for (sessions) |session| {
        const candidate = session.name orelse continue;
        if (!std.mem.eql(u8, candidate, name)) continue;
        if (found != null) return error.AmbiguousSessionName;
        found = session;
    }
    return found orelse error.SessionNotFound;
}

fn optionalUniqueWorkspace(
    workspaces: []const cmux.WorkspaceSnapshot,
    name: []const u8,
) !?cmux.WorkspaceId {
    var found: ?cmux.WorkspaceId = null;
    for (workspaces) |workspace| {
        if (!std.mem.eql(u8, workspace.name, name)) continue;
        if (found != null) return error.AmbiguousWorkspaceName;
        found = workspace.id;
    }
    return found;
}

const std = @import("std");
const cmux = @import("cmux_tui");

pub const ConnectOptions = struct {
    socket_path: []const u8,
    provider_scope_id: cmux.ProviderScopeId,
    session_id: cmux.SessionId,
    workspace_id: cmux.WorkspaceId,
    revision: u64,
    timeout_ms: ?u32 = 10_000,
};

pub const Receipt = struct {
    revision: u64,
    replayed: bool,
};

pub const ProviderController = struct {
    allocator: std.mem.Allocator,
    client: cmux.Client,
    provider_scope_id: cmux.ProviderScopeId,
    session_id: cmux.SessionId,
    workspace_id: cmux.WorkspaceId,
    revision: u64,
    generation: ?[]u8 = null,
    workspace_name: ?[]u8 = null,
    closed: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        options: ConnectOptions,
    ) !ProviderController {
        return .{
            .allocator = allocator,
            .client = try cmux.Client.connect(allocator, .{
                .socket_path = options.socket_path,
                .timeout_ms = options.timeout_ms,
            }),
            .provider_scope_id = options.provider_scope_id,
            .session_id = options.session_id,
            .workspace_id = options.workspace_id,
            .revision = options.revision,
        };
    }

    pub fn deinit(self: *ProviderController) void {
        self.client.deinit();
        if (self.generation) |value| self.allocator.free(value);
        if (self.workspace_name) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn markManaged(
        self: *ProviderController,
        managed: bool,
        idempotency_key: []const u8,
    ) !Receipt {
        try self.requireOpen();
        var result = try self.scope().markWorkspace(
            self.session_id,
            self.workspace_id,
            managed,
            try self.mutation(idempotency_key),
        );
        defer result.deinit();
        try self.validateSnapshot(result.value);
        const owned_name = try self.allocator.dupe(u8, result.value.name);
        errdefer self.allocator.free(owned_name);
        const receipt = try self.observe(
            result.generation,
            result.revision,
            result.replayed,
        );
        self.installName(owned_name);
        return receipt;
    }

    pub fn rename(
        self: *ProviderController,
        name: ?[]const u8,
        idempotency_key: []const u8,
    ) !Receipt {
        try self.requireOpen();
        var result = try self.scope().renameWorkspace(
            self.session_id,
            self.workspace_id,
            name,
            try self.mutation(idempotency_key),
        );
        defer result.deinit();
        try self.validateSnapshot(result.value);
        const owned_name = try self.allocator.dupe(u8, result.value.name);
        errdefer self.allocator.free(owned_name);
        const receipt = try self.observe(
            result.generation,
            result.revision,
            result.replayed,
        );
        self.installName(owned_name);
        return receipt;
    }

    pub fn closeWorkspace(
        self: *ProviderController,
        idempotency_key: []const u8,
    ) !Receipt {
        try self.requireOpen();
        var result = try self.scope().closeWorkspace(
            self.session_id,
            self.workspace_id,
            try self.mutation(idempotency_key),
        );
        defer result.deinit();
        const receipt = try self.observe(
            result.generation,
            result.revision,
            result.replayed,
        );
        self.closed = true;
        return receipt;
    }

    pub fn currentRevision(self: *const ProviderController) u64 {
        return self.revision;
    }

    pub fn currentName(self: *const ProviderController) ?[]const u8 {
        return self.workspace_name;
    }

    pub fn isClosed(self: *const ProviderController) bool {
        return self.closed;
    }

    pub fn lastResourceError(
        self: *const ProviderController,
    ) ?cmux.ResourceError {
        return self.client.lastResourceError();
    }

    fn scope(self: *ProviderController) cmux.ProviderScope {
        return self.client.providerScope(self.provider_scope_id);
    }

    fn mutation(
        self: *const ProviderController,
        idempotency_key: []const u8,
    ) !cmux.MutationOptions {
        return (try cmux.MutationOptions.withKey(
            idempotency_key,
        )).expecting(self.revision);
    }

    fn validateSnapshot(
        self: *const ProviderController,
        snapshot: cmux.WorkspaceSnapshot,
    ) !void {
        if (!std.meta.eql(snapshot.id, self.workspace_id) or
            !std.meta.eql(snapshot.session_id, self.session_id))
        {
            return error.SnapshotScopeMismatch;
        }
    }

    fn observe(
        self: *ProviderController,
        generation: []const u8,
        revision: u64,
        replayed: bool,
    ) !Receipt {
        if (self.generation) |known| {
            if (!std.mem.eql(u8, known, generation)) {
                return error.GenerationChanged;
            }
        }

        const next_revision = std.math.add(
            u64,
            self.revision,
            1,
        ) catch return error.RevisionOverflow;
        if (revision != next_revision and
            !(replayed and revision == self.revision))
        {
            return error.RevisionDiscontinuity;
        }

        if (self.generation == null) {
            self.generation = try self.allocator.dupe(u8, generation);
        }
        self.revision = @max(self.revision, revision);
        return .{
            .revision = revision,
            .replayed = replayed,
        };
    }

    fn installName(
        self: *ProviderController,
        owned: []u8,
    ) void {
        if (self.workspace_name) |previous| self.allocator.free(previous);
        self.workspace_name = owned;
    }

    fn requireOpen(self: *const ProviderController) !void {
        if (self.closed) return error.WorkspaceAlreadyClosed;
    }
};

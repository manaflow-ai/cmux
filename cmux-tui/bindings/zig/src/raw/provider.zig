const std = @import("std");
const capabilities = @import("capabilities.zig");
const client_module = @import("client.zig");
const protocol = @import("generated/protocol.zig");
const wire = @import("wire.zig");

pub const provider_capability = "provider-managed-workspace-authority-v2";
pub const workspace_registry_capability = "workspace-registry-v1";
pub const minimum_protocol: u32 = 9;
pub const default_origin = "cmux-zig-provider-client";

pub const Options = struct {
    authority: []const u8,
    client: client_module.Options = .{},
};

pub const Workspace = struct {
    id: u64,
    key: []u8,
    name: []u8,
    active: bool,

    fn clone(
        allocator: std.mem.Allocator,
        source: protocol.Workspace,
    ) !Workspace {
        const key = source.key orelse return error.MissingWorkspaceKey;
        return init(allocator, source.id, key, source.name, source.active);
    }

    fn init(
        allocator: std.mem.Allocator,
        id: u64,
        key: []const u8,
        name: []const u8,
        active: bool,
    ) !Workspace {
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        return .{
            .id = id,
            .key = owned_key,
            .name = try allocator.dupe(u8, name),
            .active = active,
        };
    }

    fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// Borrowed until the next snapshot, mutation, or `ProviderClient.deinit`.
pub const Snapshot = struct {
    registry_id: []const u8,
    generation: []const u8,
    workspace_revision: u64,
    workspaces: []const Workspace,
};

pub const Mutation = struct {
    workspace: u64,
    workspace_revision: u64,
    replayed: bool = false,
};

pub const CreateWorkspaceOptions = struct {
    expected_revision: u64,
    name: []const u8,
    key: []const u8,
    mutation_id: []const u8,
    origin: []const u8 = default_origin,
};

pub const RenameWorkspaceOptions = struct {
    expected_revision: u64,
    workspace: u64,
    key: []const u8,
    name: []const u8,
};

pub const CloseWorkspaceOptions = struct {
    expected_revision: u64,
    workspace: u64,
    key: []const u8,
};

/// Owns its base client, authority, and copied workspace snapshot.
///
/// `renameWorkspace` and `closeWorkspace` enforce a local expected revision
/// and validate the returned revision. Their current wire requests do not
/// carry a CAS guard, so this does not close the race with another provider
/// controller. Refresh with `snapshot` after a conflict or revision gap.
pub const ProviderClient = struct {
    allocator: std.mem.Allocator,
    client: client_module.Client,
    authority: []u8,
    registry_id: ?[]u8 = null,
    generation: ?[]u8 = null,
    workspace_revision: ?u64 = null,
    workspaces: std.ArrayList(Workspace) = .empty,
    initialized: bool = false,

    /// Connects and completes the provider handshake. Use `open` followed by
    /// `initialize` when the caller needs to take a remote handshake error.
    pub fn connect(
        allocator: std.mem.Allocator,
        options: Options,
    ) !ProviderClient {
        var result = try open(allocator, options);
        errdefer result.deinit();
        try result.initialize();
        return result;
    }

    /// Connects without performing protocol I/O.
    pub fn open(
        allocator: std.mem.Allocator,
        options: Options,
    ) !ProviderClient {
        var client_options = options.client;
        client_options.authority_policy = .provider_authority;
        const base_client = try client_module.Client.connect(
            allocator,
            client_options,
        );
        return wrapOwned(allocator, base_client, options.authority);
    }

    /// Takes ownership of a connected client and completes the handshake.
    pub fn fromOwnedClient(
        allocator: std.mem.Allocator,
        base_client: client_module.Client,
        authority: []const u8,
    ) !ProviderClient {
        var result = try wrapOwned(allocator, base_client, authority);
        errdefer result.deinit();
        try result.initialize();
        return result;
    }

    /// Takes ownership of a connected client without performing protocol I/O.
    pub fn wrapOwned(
        allocator: std.mem.Allocator,
        base_client: client_module.Client,
        authority: []const u8,
    ) !ProviderClient {
        var owned_client = base_client;
        errdefer owned_client.deinit();
        owned_client.authority_policy = .provider_authority;
        const owned_authority = try allocator.dupe(u8, authority);
        return .{
            .allocator = allocator,
            .client = owned_client,
            .authority = owned_authority,
        };
    }

    pub fn deinit(self: *ProviderClient) void {
        self.clearSnapshot();
        self.client.deinit();
        secureFreeBytes(self.allocator, self.authority);
        self.* = undefined;
    }

    /// Identifies the mux, validates protocol and capabilities, marks provider
    /// ownership, and retains an allocator-owned workspace snapshot.
    pub fn initialize(self: *ProviderClient) !void {
        self.discardRemoteError();
        if (self.initialized) return error.AlreadyInitialized;

        var identity = try protocol.identify(&self.client, .{});
        defer identity.deinit();
        try validateIdentity(identity.value);

        var marked = try protocol.markWorkspacesProviderManaged(
            &self.client,
            .{ .authority = self.authority },
        );
        defer marked.deinit();

        var tree = try protocol.listWorkspaces(&self.client, .{});
        defer tree.deinit();
        try validateInitialTree(identity.value, tree.value);

        var copied_workspaces = try cloneWorkspaces(
            self.allocator,
            tree.value.workspaces,
        );
        errdefer freeWorkspaces(self.allocator, &copied_workspaces);
        const registry_id = try self.allocator.dupe(
            u8,
            identity.value.registry_id,
        );
        errdefer self.allocator.free(registry_id);
        const generation = try self.allocator.dupe(
            u8,
            identity.value.generation,
        );
        errdefer self.allocator.free(generation);

        self.registry_id = registry_id;
        self.generation = generation;
        self.workspace_revision =
            tree.value.workspace_revision orelse identity.value.workspace_revision;
        self.workspaces = copied_workspaces;
        self.initialized = true;
    }

    /// Fetches and retains a fresh workspace snapshot.
    pub fn snapshot(self: *ProviderClient) !Snapshot {
        self.discardRemoteError();
        try self.requireInitialized();

        var tree = try protocol.listWorkspaces(&self.client, .{});
        defer tree.deinit();
        const revision = try self.validateCurrentTree(tree.value);
        var copied_workspaces = try cloneWorkspaces(
            self.allocator,
            tree.value.workspaces,
        );
        errdefer freeWorkspaces(self.allocator, &copied_workspaces);

        freeWorkspaces(self.allocator, &self.workspaces);
        self.workspaces = copied_workspaces;
        self.workspace_revision = revision;
        return self.currentSnapshot();
    }

    pub fn currentSnapshot(self: *const ProviderClient) !Snapshot {
        try self.requireInitialized();
        return .{
            .registry_id = self.registry_id.?,
            .generation = self.generation.?,
            .workspace_revision = self.workspace_revision.?,
            .workspaces = self.workspaces.items,
        };
    }

    pub fn createWorkspace(
        self: *ProviderClient,
        options: CreateWorkspaceOptions,
    ) !Mutation {
        self.discardRemoteError();
        try self.requireRevision(options.expected_revision);
        try self.workspaces.ensureUnusedCapacity(self.allocator, 1);
        var pending_workspace = try Workspace.init(
            self.allocator,
            0,
            options.key,
            options.name,
            false,
        );
        var pending_owned = true;
        defer if (pending_owned) pending_workspace.deinit(self.allocator);

        var result = try protocol.createWorkspace(&self.client, .{
            .name = wire.Field([]const u8).some(options.name),
            .key = wire.Field([]const u8).some(options.key),
            .origin = wire.Field([]const u8).some(options.origin),
            .mutation_id = wire.Field([]const u8).some(options.mutation_id),
            .expected_generation = wire.Field([]const u8).some(
                self.generation.?,
            ),
            .expected_revision = wire.Field(u64).some(
                options.expected_revision,
            ),
        });
        defer result.deinit();
        try self.validateMutationEnvelope(
            result.value.registry_id,
            result.value.generation,
        );
        const next_revision = try revisionAfter(options.expected_revision);
        if (result.value.replayed) {
            if (result.value.workspace_revision > next_revision) {
                return error.RevisionGap;
            }
        } else if (result.value.workspace_revision != next_revision) {
            return error.RevisionGap;
        }
        if (!std.mem.eql(u8, result.value.key, options.key)) {
            return error.MutationSelectorMismatch;
        }

        if (result.value.replayed) {
            _ = try self.snapshot();
        } else {
            if (findWorkspaceIndex(self.workspaces.items, result.value.workspace) != null) {
                return error.DuplicateWorkspace;
            }
            const insertion_index = std.math.cast(
                usize,
                result.value.index,
            ) orelse return error.InvalidWorkspaceIndex;
            if (insertion_index > self.workspaces.items.len) {
                return error.InvalidWorkspaceIndex;
            }
            pending_workspace.id = result.value.workspace;
            self.workspaces.insertAssumeCapacity(
                insertion_index,
                pending_workspace,
            );
            pending_owned = false;
            self.workspace_revision = result.value.workspace_revision;
        }

        return .{
            .workspace = result.value.workspace,
            .workspace_revision = result.value.workspace_revision,
            .replayed = result.value.replayed,
        };
    }

    pub fn renameWorkspace(
        self: *ProviderClient,
        options: RenameWorkspaceOptions,
    ) !Mutation {
        self.discardRemoteError();
        try self.requireRevision(options.expected_revision);
        const index = try self.requireWorkspace(options.workspace, options.key);
        const owned_name = try self.allocator.dupe(u8, options.name);
        var name_owned = true;
        defer if (name_owned) self.allocator.free(owned_name);

        var result = try protocol.renameProviderManagedWorkspace(
            &self.client,
            .{
                .authority = self.authority,
                .workspace = options.workspace,
                .key = options.key,
                .name = options.name,
            },
        );
        defer result.deinit();
        try validateProviderResult(
            options.workspace,
            options.key,
            options.expected_revision,
            result.value,
        );

        self.allocator.free(self.workspaces.items[index].name);
        self.workspaces.items[index].name = owned_name;
        name_owned = false;
        self.workspace_revision = result.value.workspace_revision;
        return .{
            .workspace = result.value.workspace,
            .workspace_revision = result.value.workspace_revision,
        };
    }

    pub fn closeWorkspace(
        self: *ProviderClient,
        options: CloseWorkspaceOptions,
    ) !Mutation {
        self.discardRemoteError();
        try self.requireRevision(options.expected_revision);
        const index = try self.requireWorkspace(options.workspace, options.key);

        var result = try protocol.closeProviderManagedWorkspace(
            &self.client,
            .{
                .authority = self.authority,
                .workspace = options.workspace,
                .key = options.key,
            },
        );
        defer result.deinit();
        try validateProviderResult(
            options.workspace,
            options.key,
            options.expected_revision,
            result.value,
        );

        var removed = self.workspaces.orderedRemove(index);
        removed.deinit(self.allocator);
        self.workspace_revision = result.value.workspace_revision;
        return .{
            .workspace = result.value.workspace,
            .workspace_revision = result.value.workspace_revision,
        };
    }

    pub fn lastRemoteError(self: *const ProviderClient) ?[]const u8 {
        return self.client.lastRemoteError();
    }

    pub fn takeRemoteError(
        self: *ProviderClient,
    ) ?client_module.OwnedRemoteError {
        return self.client.takeRemoteError();
    }

    fn discardRemoteError(self: *ProviderClient) void {
        if (self.client.takeRemoteError()) |owned| {
            var remote_error = owned;
            remote_error.deinit();
        }
    }

    fn requireInitialized(self: *const ProviderClient) !void {
        if (!self.initialized) return error.NotInitialized;
    }

    fn requireRevision(
        self: *const ProviderClient,
        expected_revision: u64,
    ) !void {
        try self.requireInitialized();
        if (self.workspace_revision.? != expected_revision) {
            return error.LocalRevisionConflict;
        }
    }

    fn requireWorkspace(
        self: *const ProviderClient,
        workspace: u64,
        key: []const u8,
    ) !usize {
        const index = findWorkspaceIndex(
            self.workspaces.items,
            workspace,
        ) orelse return error.UnknownWorkspace;
        if (!std.mem.eql(u8, self.workspaces.items[index].key, key)) {
            return error.MutationSelectorMismatch;
        }
        return index;
    }

    fn validateMutationEnvelope(
        self: *const ProviderClient,
        registry_id: []const u8,
        generation: []const u8,
    ) !void {
        if (!std.mem.eql(u8, self.registry_id.?, registry_id)) {
            return error.RegistryChanged;
        }
        if (!std.mem.eql(u8, self.generation.?, generation)) {
            return error.GenerationChanged;
        }
    }

    fn validateCurrentTree(
        self: *const ProviderClient,
        tree: protocol.Tree,
    ) !u64 {
        const registry_id = tree.registry_id orelse
            return error.MissingRegistryId;
        if (!std.mem.eql(u8, self.registry_id.?, registry_id)) {
            return error.RegistryChanged;
        }
        const generation = tree.generation orelse
            return error.MissingGeneration;
        if (!std.mem.eql(u8, self.generation.?, generation)) {
            return error.GenerationChanged;
        }
        const revision = tree.workspace_revision orelse
            return error.MissingWorkspaceRevision;
        if (revision < self.workspace_revision.?) {
            return error.RevisionRegressed;
        }
        return revision;
    }

    fn clearSnapshot(self: *ProviderClient) void {
        freeWorkspaces(self.allocator, &self.workspaces);
        if (self.registry_id) |registry_id| self.allocator.free(registry_id);
        if (self.generation) |generation| self.allocator.free(generation);
        self.registry_id = null;
        self.generation = null;
        self.workspace_revision = null;
        self.initialized = false;
    }
};

fn validateIdentity(identity: protocol.IdentifyResult) !void {
    if (!std.mem.eql(u8, identity.app, "cmux-tui")) {
        return error.UnexpectedServer;
    }
    if (identity.protocol < minimum_protocol) {
        return error.UnsupportedProtocol;
    }
    const server_capabilities = identity.capabilities orelse &.{};
    if (!capabilities.hasCapability(
        server_capabilities,
        workspace_registry_capability,
    )) {
        return error.MissingWorkspaceRegistryCapability;
    }
    if (!capabilities.hasCapability(
        server_capabilities,
        provider_capability,
    )) {
        return error.MissingProviderCapability;
    }
}

fn validateInitialTree(
    identity: protocol.IdentifyResult,
    tree: protocol.Tree,
) !void {
    const registry_id = tree.registry_id orelse return error.MissingRegistryId;
    if (!std.mem.eql(u8, identity.registry_id, registry_id)) {
        return error.RegistryChanged;
    }
    const generation = tree.generation orelse return error.MissingGeneration;
    if (!std.mem.eql(u8, identity.generation, generation)) {
        return error.GenerationChanged;
    }
    const revision = tree.workspace_revision orelse
        return error.MissingWorkspaceRevision;
    if (revision < identity.workspace_revision) return error.RevisionRegressed;
}

fn validateProviderResult(
    workspace: u64,
    key: []const u8,
    expected_revision: u64,
    result: protocol.ProviderWorkspaceMutationResult,
) !void {
    if (result.workspace != workspace or !std.mem.eql(u8, result.key, key)) {
        return error.MutationSelectorMismatch;
    }
    if (result.workspace_revision != try revisionAfter(expected_revision)) {
        return error.RevisionGap;
    }
}

fn revisionAfter(revision: u64) !u64 {
    return std.math.add(u64, revision, 1) catch error.RevisionOverflow;
}

fn secureFreeBytes(allocator: std.mem.Allocator, bytes: []u8) void {
    if (bytes.len == 0) return;
    std.crypto.secureZero(u8, bytes);
    // Allocator.free writes `undefined` before rawFree, which would overwrite
    // the secure zeroes.
    allocator.rawFree(bytes, .of(u8), @returnAddress());
}

fn cloneWorkspaces(
    allocator: std.mem.Allocator,
    sources: []const protocol.Workspace,
) !std.ArrayList(Workspace) {
    var result: std.ArrayList(Workspace) = .empty;
    errdefer freeWorkspaces(allocator, &result);
    try result.ensureTotalCapacity(allocator, sources.len);
    for (sources) |source| {
        const workspace = try Workspace.clone(allocator, source);
        result.appendAssumeCapacity(workspace);
    }
    return result;
}

fn freeWorkspaces(
    allocator: std.mem.Allocator,
    workspaces: *std.ArrayList(Workspace),
) void {
    for (workspaces.items) |*workspace| workspace.deinit(allocator);
    workspaces.deinit(allocator);
    workspaces.* = .empty;
}

fn findWorkspaceIndex(workspaces: []const Workspace, id: u64) ?usize {
    for (workspaces, 0..) |workspace, index| {
        if (workspace.id == id) return index;
    }
    return null;
}

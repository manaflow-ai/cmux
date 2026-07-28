const std = @import("std");
const cmux = @import("cmux_tui");

pub const provider_capability = "provider-managed-workspace-authority-v2";
pub const mutation_origin = "zig-provider-controller";
pub const minimum_provider_protocol: u32 = 9;

pub const Workspace = struct {
    id: u64,
    key: []u8,
    name: []u8,
    active: bool,

    fn clone(
        allocator: std.mem.Allocator,
        source: cmux.protocol.Workspace,
    ) !Workspace {
        const key = source.key orelse return error.MissingWorkspaceKey;
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        return .{
            .id = source.id,
            .key = owned_key,
            .name = try allocator.dupe(u8, source.name),
            .active = source.active,
        };
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

pub const Mutation = struct {
    workspace: u64,
    workspace_revision: u64,
    replayed: bool = false,
};

pub const ConnectOptions = struct {
    socket_path: []const u8,
    authority: []const u8,
    timeout_ms: ?u32 = 10_000,
    limits: cmux.Limits = .{},
};

pub const ProviderController = struct {
    allocator: std.mem.Allocator,
    client: cmux.Client,
    authority: []u8,
    registry_id: ?[]u8 = null,
    generation: ?[]u8 = null,
    workspace_revision: ?u64 = null,
    workspaces_owned: std.ArrayList(Workspace) = .empty,
    initialized: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        options: ConnectOptions,
    ) !ProviderController {
        const authority = try allocator.dupe(u8, options.authority);
        errdefer {
            @memset(authority, 0);
            allocator.free(authority);
        }
        return .{
            .allocator = allocator,
            .client = try cmux.Client.connect(allocator, .{
                .socket_path = options.socket_path,
                .timeout_ms = options.timeout_ms,
                .limits = options.limits,
                .authority_policy = .provider_authority,
            }),
            .authority = authority,
        };
    }

    pub fn deinit(self: *ProviderController) void {
        self.clearTopology();
        self.client.deinit();
        @memset(self.authority, 0);
        self.allocator.free(self.authority);
        self.* = undefined;
    }

    pub fn initialize(self: *ProviderController) !void {
        if (self.initialized) return error.AlreadyInitialized;

        var identity = try cmux.protocol.identify(&self.client, .{});
        defer identity.deinit();
        try validateIdentity(identity.value);

        var marked = try cmux.protocol.markWorkspacesProviderManaged(
            &self.client,
            .{ .authority = self.authority },
        );
        defer marked.deinit();

        var tree = try cmux.protocol.listWorkspaces(&self.client, .{});
        defer tree.deinit();

        var cloned = try cloneWorkspaces(self.allocator, tree.value.workspaces);
        errdefer freeWorkspaces(self.allocator, &cloned);
        try validateTree(identity.value, tree.value);

        const registry_id = try self.allocator.dupe(u8, identity.value.registry_id);
        errdefer self.allocator.free(registry_id);
        const generation = try self.allocator.dupe(u8, identity.value.generation);
        errdefer self.allocator.free(generation);

        self.registry_id = registry_id;
        self.generation = generation;
        self.workspace_revision =
            tree.value.workspace_revision orelse identity.value.workspace_revision;
        self.workspaces_owned = cloned;
        self.initialized = true;
    }

    pub fn refresh(self: *ProviderController) !void {
        try self.requireInitialized();
        var tree = try cmux.protocol.listWorkspaces(&self.client, .{});
        defer tree.deinit();
        try self.validateCurrentTree(tree.value);
        const revision = tree.value.workspace_revision orelse
            return error.MissingWorkspaceRevision;
        if (revision < self.workspace_revision.?) return error.RevisionRegressed;

        var cloned = try cloneWorkspaces(self.allocator, tree.value.workspaces);
        errdefer freeWorkspaces(self.allocator, &cloned);
        freeWorkspaces(self.allocator, &self.workspaces_owned);
        self.workspaces_owned = cloned;
        self.workspace_revision = revision;
    }

    pub fn createWorkspace(
        self: *ProviderController,
        expected_revision: u64,
        name: []const u8,
        key: []const u8,
        mutation_id: []const u8,
    ) !Mutation {
        try self.requireRevision(expected_revision);
        var result = try cmux.protocol.createWorkspace(&self.client, .{
            .name = cmux.Field([]const u8).some(name),
            .key = cmux.Field([]const u8).some(key),
            .origin = cmux.Field([]const u8).some(mutation_origin),
            .mutation_id = cmux.Field([]const u8).some(mutation_id),
            .expected_generation = cmux.Field([]const u8).some(self.generation.?),
            .expected_revision = cmux.Field(u64).some(expected_revision),
        });
        defer result.deinit();
        try self.validateMutationEnvelope(
            result.value.registry_id,
            result.value.generation,
        );
        try self.observeCreateRevision(
            result.value.workspace_revision,
            result.value.replayed,
        );
        if (!std.mem.eql(u8, result.value.key, key)) {
            return error.MutationSelectorMismatch;
        }

        if (findWorkspaceIndex(self.workspaces_owned.items, result.value.workspace)) |index| {
            if (!result.value.replayed) return error.DuplicateWorkspace;
            if (!std.mem.eql(u8, self.workspaces_owned.items[index].key, key)) {
                return error.MutationSelectorMismatch;
            }
        } else {
            var workspace = try Workspace.init(
                self.allocator,
                result.value.workspace,
                key,
                name,
                false,
            );
            errdefer workspace.deinit(self.allocator);
            const insertion_index: usize = @intCast(result.value.index);
            if (insertion_index > self.workspaces_owned.items.len) {
                return error.InvalidWorkspaceIndex;
            }
            try self.workspaces_owned.insert(
                self.allocator,
                insertion_index,
                workspace,
            );
        }
        self.workspace_revision = @max(
            self.workspace_revision.?,
            result.value.workspace_revision,
        );
        return .{
            .workspace = result.value.workspace,
            .workspace_revision = result.value.workspace_revision,
            .replayed = result.value.replayed,
        };
    }

    pub fn renameWorkspace(
        self: *ProviderController,
        expected_revision: u64,
        workspace_id: u64,
        key: []const u8,
        name: []const u8,
    ) !Mutation {
        try self.requireRevision(expected_revision);
        const index = try self.requireWorkspace(workspace_id, key);
        var result = try cmux.protocol.renameProviderManagedWorkspace(
            &self.client,
            .{
                .authority = self.authority,
                .workspace = workspace_id,
                .key = key,
                .name = name,
            },
        );
        defer result.deinit();
        try validateProviderResult(
            workspace_id,
            key,
            result.value,
            expected_revision,
        );

        const owned_name = try self.allocator.dupe(u8, name);
        self.allocator.free(self.workspaces_owned.items[index].name);
        self.workspaces_owned.items[index].name = owned_name;
        self.workspace_revision = result.value.workspace_revision;
        return .{
            .workspace = workspace_id,
            .workspace_revision = result.value.workspace_revision,
        };
    }

    pub fn closeWorkspace(
        self: *ProviderController,
        expected_revision: u64,
        workspace_id: u64,
        key: []const u8,
    ) !Mutation {
        try self.requireRevision(expected_revision);
        const index = try self.requireWorkspace(workspace_id, key);
        var result = try cmux.protocol.closeProviderManagedWorkspace(
            &self.client,
            .{
                .authority = self.authority,
                .workspace = workspace_id,
                .key = key,
            },
        );
        defer result.deinit();
        try validateProviderResult(
            workspace_id,
            key,
            result.value,
            expected_revision,
        );

        var removed = self.workspaces_owned.orderedRemove(index);
        removed.deinit(self.allocator);
        self.workspace_revision = result.value.workspace_revision;
        return .{
            .workspace = workspace_id,
            .workspace_revision = result.value.workspace_revision,
        };
    }

    pub fn lastRemoteError(self: *const ProviderController) ?[]const u8 {
        return self.client.lastRemoteError();
    }

    pub fn registryId(self: *const ProviderController) ![]const u8 {
        try self.requireInitialized();
        return self.registry_id.?;
    }

    pub fn generationId(self: *const ProviderController) ![]const u8 {
        try self.requireInitialized();
        return self.generation.?;
    }

    pub fn workspaceRevision(self: *const ProviderController) !u64 {
        try self.requireInitialized();
        return self.workspace_revision.?;
    }

    pub fn workspaces(self: *const ProviderController) ![]const Workspace {
        try self.requireInitialized();
        return self.workspaces_owned.items;
    }

    fn requireInitialized(self: *const ProviderController) !void {
        if (!self.initialized) return error.NotInitialized;
    }

    fn requireRevision(
        self: *const ProviderController,
        expected_revision: u64,
    ) !void {
        try self.requireInitialized();
        if (expected_revision != self.workspace_revision.?) {
            return error.LocalRevisionConflict;
        }
    }

    fn requireWorkspace(
        self: *const ProviderController,
        workspace_id: u64,
        key: []const u8,
    ) !usize {
        const index = findWorkspaceIndex(
            self.workspaces_owned.items,
            workspace_id,
        ) orelse return error.UnknownWorkspace;
        if (!std.mem.eql(u8, self.workspaces_owned.items[index].key, key)) {
            return error.MutationSelectorMismatch;
        }
        return index;
    }

    fn validateMutationEnvelope(
        self: *const ProviderController,
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

    fn observeCreateRevision(
        self: *const ProviderController,
        revision: u64,
        replayed: bool,
    ) !void {
        const current = self.workspace_revision.?;
        if (replayed) {
            if (revision > current +| 1) return error.RevisionDiscontinuity;
            return;
        }
        if (revision != current +| 1) return error.RevisionDiscontinuity;
    }

    fn validateProviderResult(
        workspace_id: u64,
        key: []const u8,
        result: cmux.protocol.ProviderWorkspaceMutationResult,
        expected_revision: u64,
    ) !void {
        if (result.workspace != workspace_id or
            !std.mem.eql(u8, result.key, key))
        {
            return error.MutationSelectorMismatch;
        }
        if (result.workspace_revision != expected_revision +| 1) {
            return error.RevisionDiscontinuity;
        }
    }

    fn validateCurrentTree(
        self: *const ProviderController,
        tree: cmux.protocol.Tree,
    ) !void {
        if (tree.registry_id) |registry_id| {
            if (!std.mem.eql(u8, self.registry_id.?, registry_id)) {
                return error.RegistryChanged;
            }
        } else return error.MissingRegistryId;
        if (tree.generation) |generation| {
            if (!std.mem.eql(u8, self.generation.?, generation)) {
                return error.GenerationChanged;
            }
        } else return error.MissingGeneration;
    }

    fn clearTopology(self: *ProviderController) void {
        freeWorkspaces(self.allocator, &self.workspaces_owned);
        if (self.registry_id) |registry_id| self.allocator.free(registry_id);
        if (self.generation) |generation| self.allocator.free(generation);
        self.registry_id = null;
        self.generation = null;
        self.workspace_revision = null;
        self.initialized = false;
    }
};

fn validateIdentity(identity: cmux.protocol.IdentifyResult) !void {
    if (!std.mem.eql(u8, identity.app, "cmux-tui")) {
        return error.UnexpectedServer;
    }
    if (identity.protocol < minimum_provider_protocol) {
        return error.UnsupportedProtocol;
    }
    const server_capabilities = identity.capabilities orelse &.{};
    if (!cmux.hasCapability(server_capabilities, provider_capability)) {
        return error.MissingProviderCapability;
    }
}

fn validateTree(
    identity: cmux.protocol.IdentifyResult,
    tree: cmux.protocol.Tree,
) !void {
    const registry_id = tree.registry_id orelse return error.MissingRegistryId;
    if (!std.mem.eql(u8, registry_id, identity.registry_id)) {
        return error.RegistryChanged;
    }
    const generation = tree.generation orelse return error.MissingGeneration;
    if (!std.mem.eql(u8, generation, identity.generation)) {
        return error.GenerationChanged;
    }
    const revision = tree.workspace_revision orelse
        return error.MissingWorkspaceRevision;
    if (revision < identity.workspace_revision) return error.RevisionRegressed;
}

fn cloneWorkspaces(
    allocator: std.mem.Allocator,
    sources: []const cmux.protocol.Workspace,
) !std.ArrayList(Workspace) {
    var result: std.ArrayList(Workspace) = .empty;
    errdefer freeWorkspaces(allocator, &result);
    try result.ensureTotalCapacity(allocator, sources.len);
    for (sources) |source| {
        try result.append(allocator, try Workspace.clone(allocator, source));
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

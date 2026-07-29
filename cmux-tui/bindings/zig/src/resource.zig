const std = @import("std");
const raw = @import("raw.zig");

pub const OperationClass = enum {
    read,
    mutation,
    stream_open,
    connection_control,
};

/// Handwritten intent-layer inventory. `terminal.create` remains raw-only.
pub const Operation = enum {
    machine_list,
    machine_get,
    machine_create,
    machine_rename,
    machine_delete,
    machine_restore,
    machine_purge,
    machine_connect_external,
    session_list,
    session_open,
    session_get,
    session_snapshot,
    session_events,
    session_ping,
    session_shutdown,
    session_reload_config,
    session_terminal_defaults_update,
    client_list,
    client_get,
    client_metadata_update,
    client_sizing_set,
    client_sizing_release,
    client_cell_pixels_set,
    client_detach,
    session_window_title_set,
    session_window_title_clear,
    pairing_request_list,
    pairing_request_resolve,
    frontend_projection_get,
    frontend_projection_put,
    workspace_list,
    workspace_get,
    workspace_create,
    workspace_rename,
    workspace_move,
    workspace_focus,
    workspace_close,
    workspace_run,
    workspace_layout_apply,
    screen_list,
    screen_get,
    screen_create,
    screen_rename,
    screen_focus,
    screen_close,
    screen_layout_export,
    screen_layout_undo,
    pane_list,
    pane_get,
    pane_create,
    pane_split,
    pane_rename,
    pane_focus,
    pane_focus_direction,
    pane_neighbor_get,
    pane_swap,
    pane_zoom,
    pane_split_ratio_set,
    pane_viewport_width_set,
    pane_close,
    pane_run,
    tab_list,
    tab_get,
    tab_create_terminal,
    tab_create_browser,
    tab_rename,
    tab_move,
    tab_focus,
    tab_close,
    terminal_list,
    terminal_get,
    terminal_input_write,
    terminal_input_keys,
    terminal_input_mouse,
    terminal_input_focus,
    terminal_screen_read,
    terminal_state_read,
    terminal_history_read,
    terminal_history_clear,
    terminal_wait,
    terminal_copy,
    terminal_process_get,
    terminal_renderer_grant_create,
    terminal_viewer_resize,
    terminal_viewer_release,
    terminal_viewport_scroll,
    terminal_move,
    terminal_attach,
    terminal_close,
    browser_list,
    browser_get,
    browser_navigate,
    browser_back,
    browser_forward,
    browser_reload,
    browser_activate,
    browser_input_key,
    browser_input_text,
    browser_input_mouse,
    browser_input_wheel,
    browser_viewer_resize,
    browser_viewer_release,
    browser_attach,
    browser_close,
    notification_list,
    notification_create,
    agent_list,
    agent_report,
    sidebar_view_get,
    sidebar_view_ensure,
    sidebar_view_attach,
    sidebar_view_input,
    sidebar_view_resize,
    sidebar_view_reload,
    provider_scope_list,
    provider_action_invoke,
    provider_notice_acknowledge,
    provider_notice_events,
    provider_workspace_mark,
    provider_workspace_rename,
    provider_workspace_close,
    stream_cancel,

    pub fn wireName(self: Operation) []const u8 {
        return switch (self) {
            .machine_list => "machine.list",
            .machine_get => "machine.get",
            .machine_create => "machine.create",
            .machine_rename => "machine.rename",
            .machine_delete => "machine.delete",
            .machine_restore => "machine.restore",
            .machine_purge => "machine.purge",
            .machine_connect_external => "machine.connect_external",
            .session_list => "session.list",
            .session_open => "session.open",
            .session_get => "session.get",
            .session_snapshot => "session.snapshot",
            .session_events => "session.events",
            .session_ping => "session.ping",
            .session_shutdown => "session.shutdown",
            .session_reload_config => "session.reload_config",
            .session_terminal_defaults_update => "session.terminal_defaults.update",
            .client_list => "client.list",
            .client_get => "client.get",
            .client_metadata_update => "client.metadata.update",
            .client_sizing_set => "client.sizing.set",
            .client_sizing_release => "client.sizing.release",
            .client_cell_pixels_set => "client.cell_pixels.set",
            .client_detach => "client.detach",
            .session_window_title_set => "session.window.title.set",
            .session_window_title_clear => "session.window.title.clear",
            .pairing_request_list => "pairing_request.list",
            .pairing_request_resolve => "pairing_request.resolve",
            .frontend_projection_get => "frontend_projection.get",
            .frontend_projection_put => "frontend_projection.put",
            .workspace_list => "workspace.list",
            .workspace_get => "workspace.get",
            .workspace_create => "workspace.create",
            .workspace_rename => "workspace.rename",
            .workspace_move => "workspace.move",
            .workspace_focus => "workspace.focus",
            .workspace_close => "workspace.close",
            .workspace_run => "workspace.run",
            .workspace_layout_apply => "workspace.layout.apply",
            .screen_list => "screen.list",
            .screen_get => "screen.get",
            .screen_create => "screen.create",
            .screen_rename => "screen.rename",
            .screen_focus => "screen.focus",
            .screen_close => "screen.close",
            .screen_layout_export => "screen.layout.export",
            .screen_layout_undo => "screen.layout.undo",
            .pane_list => "pane.list",
            .pane_get => "pane.get",
            .pane_create => "pane.create",
            .pane_split => "pane.split",
            .pane_rename => "pane.rename",
            .pane_focus => "pane.focus",
            .pane_focus_direction => "pane.focus_direction",
            .pane_neighbor_get => "pane.neighbor.get",
            .pane_swap => "pane.swap",
            .pane_zoom => "pane.zoom",
            .pane_split_ratio_set => "pane.split_ratio.set",
            .pane_viewport_width_set => "pane.viewport_width.set",
            .pane_close => "pane.close",
            .pane_run => "pane.run",
            .tab_list => "tab.list",
            .tab_get => "tab.get",
            .tab_create_terminal => "tab.create_terminal",
            .tab_create_browser => "tab.create_browser",
            .tab_rename => "tab.rename",
            .tab_move => "tab.move",
            .tab_focus => "tab.focus",
            .tab_close => "tab.close",
            .terminal_list => "terminal.list",
            .terminal_get => "terminal.get",
            .terminal_input_write => "terminal.input.write",
            .terminal_input_keys => "terminal.input.keys",
            .terminal_input_mouse => "terminal.input.mouse",
            .terminal_input_focus => "terminal.input.focus",
            .terminal_screen_read => "terminal.screen.read",
            .terminal_state_read => "terminal.state.read",
            .terminal_history_read => "terminal.history.read",
            .terminal_history_clear => "terminal.history.clear",
            .terminal_wait => "terminal.wait",
            .terminal_copy => "terminal.copy",
            .terminal_process_get => "terminal.process.get",
            .terminal_renderer_grant_create => "terminal.renderer_grant.create",
            .terminal_viewer_resize => "terminal.viewer.resize",
            .terminal_viewer_release => "terminal.viewer.release",
            .terminal_viewport_scroll => "terminal.viewport.scroll",
            .terminal_move => "terminal.move",
            .terminal_attach => "terminal.attach",
            .terminal_close => "terminal.close",
            .browser_list => "browser.list",
            .browser_get => "browser.get",
            .browser_navigate => "browser.navigate",
            .browser_back => "browser.back",
            .browser_forward => "browser.forward",
            .browser_reload => "browser.reload",
            .browser_activate => "browser.activate",
            .browser_input_key => "browser.input.key",
            .browser_input_text => "browser.input.text",
            .browser_input_mouse => "browser.input.mouse",
            .browser_input_wheel => "browser.input.wheel",
            .browser_viewer_resize => "browser.viewer.resize",
            .browser_viewer_release => "browser.viewer.release",
            .browser_attach => "browser.attach",
            .browser_close => "browser.close",
            .notification_list => "notification.list",
            .notification_create => "notification.create",
            .agent_list => "agent.list",
            .agent_report => "agent.report",
            .sidebar_view_get => "sidebar_view.get",
            .sidebar_view_ensure => "sidebar_view.ensure",
            .sidebar_view_attach => "sidebar_view.attach",
            .sidebar_view_input => "sidebar_view.input",
            .sidebar_view_resize => "sidebar_view.resize",
            .sidebar_view_reload => "sidebar_view.reload",
            .provider_scope_list => "provider_scope.list",
            .provider_action_invoke => "provider_action.invoke",
            .provider_notice_acknowledge => "provider_notice.acknowledge",
            .provider_notice_events => "provider_notice.events",
            .provider_workspace_mark => "provider_workspace.mark",
            .provider_workspace_rename => "provider_workspace.rename",
            .provider_workspace_close => "provider_workspace.close",
            .stream_cancel => "stream.cancel",
        };
    }

    pub fn class(self: Operation) OperationClass {
        return switch (self) {
            .session_events,
            .terminal_attach,
            .browser_attach,
            .sidebar_view_attach,
            .provider_notice_events,
            => .stream_open,

            .stream_cancel,
            .provider_notice_acknowledge,
            .client_metadata_update,
            .client_sizing_set,
            .client_sizing_release,
            .client_cell_pixels_set,
            .client_detach,
            .terminal_renderer_grant_create,
            .terminal_viewer_resize,
            .terminal_viewer_release,
            .browser_viewer_resize,
            .browser_viewer_release,
            => .connection_control,

            .machine_list,
            .machine_get,
            .session_list,
            .session_get,
            .session_snapshot,
            .session_ping,
            .client_list,
            .client_get,
            .pairing_request_list,
            .frontend_projection_get,
            .workspace_list,
            .workspace_get,
            .screen_list,
            .screen_get,
            .screen_layout_export,
            .pane_list,
            .pane_get,
            .pane_neighbor_get,
            .tab_list,
            .tab_get,
            .terminal_list,
            .terminal_get,
            .terminal_screen_read,
            .terminal_state_read,
            .terminal_history_read,
            .terminal_wait,
            .terminal_copy,
            .terminal_process_get,
            .browser_list,
            .browser_get,
            .notification_list,
            .agent_list,
            .sidebar_view_get,
            .provider_scope_list,
            => .read,

            else => .mutation,
        };
    }

    fn requiresMachine(self: Operation) bool {
        return switch (self) {
            .machine_list,
            .machine_create,
            .machine_connect_external,
            => false,
            else => true,
        };
    }

    fn requiresSession(self: Operation) bool {
        return switch (self) {
            .machine_list,
            .machine_get,
            .machine_create,
            .machine_rename,
            .machine_delete,
            .machine_restore,
            .machine_purge,
            .machine_connect_external,
            .session_list,
            .provider_scope_list,
            .provider_action_invoke,
            .provider_notice_acknowledge,
            .provider_notice_events,
            => false,
            else => true,
        };
    }

    fn supportsExpectedRevision(self: Operation) bool {
        return self.class() == .mutation and switch (self) {
            .machine_create,
            .machine_connect_external,
            .workspace_create,
            => false,
            else => true,
        };
    }
};

fn OpaqueId(comptime prefix: []const u8) type {
    return struct {
        const Self = @This();
        pub const wire_prefix = prefix;
        pub const encoded_len = prefix.len + 32;

        bytes: [encoded_len]u8,

        pub fn parse(value: []const u8) !Self {
            if (value.len != encoded_len or
                !std.mem.startsWith(u8, value, prefix))
            {
                return error.InvalidResourceId;
            }
            for (value[prefix.len..]) |byte| {
                if (!((byte >= '0' and byte <= '9') or
                    (byte >= 'a' and byte <= 'f')))
                {
                    return error.InvalidResourceId;
                }
            }
            var result: Self = undefined;
            @memcpy(&result.bytes, value);
            return result;
        }

        pub fn slice(self: *const Self) []const u8 {
            return &self.bytes;
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.writeAll(&self.bytes);
        }
    };
}

pub const MachineId = OpaqueId("machine_");
pub const SessionId = OpaqueId("session_");
pub const WorkspaceId = OpaqueId("ws_");
pub const ScreenId = OpaqueId("screen_");
pub const PaneId = OpaqueId("pane_");
pub const TabId = OpaqueId("tab_");
pub const TerminalId = OpaqueId("term_");
pub const BrowserId = OpaqueId("browser_");
pub const ConnectedClientId = OpaqueId("client_");
pub const SplitId = OpaqueId("split_");
pub const NotificationId = OpaqueId("notification_");
pub const AgentId = OpaqueId("agent_");
pub const StreamId = OpaqueId("stream_");
pub const FrontendProjectionId = OpaqueId("projection_");
pub const PairingRequestId = OpaqueId("pairing_");
pub const SidebarViewId = OpaqueId("sidebar_view_");
pub const ProviderScopeId = OpaqueId("provider_scope_");
pub const ProviderActionId = OpaqueId("provider_action_");
pub const ProviderNoticeId = OpaqueId("provider_notice_");

pub fn Selector(comptime Id: type) type {
    return union(enum) {
        const Self = @This();

        id: Id,
        current,
        name: []const u8,

        pub fn byId(value: Id) Self {
            return .{ .id = value };
        }

        pub fn currentValue() Self {
            return .current;
        }

        pub fn named(value: []const u8) Self {
            return .{ .name = value };
        }

        pub fn formatAlloc(
            self: Self,
            allocator: std.mem.Allocator,
        ) ![]u8 {
            return switch (self) {
                .id => |value| allocator.dupe(u8, value.slice()),
                .current => allocator.dupe(u8, "current"),
                .name => |value| std.fmt.allocPrint(
                    allocator,
                    "name:{s}",
                    .{value},
                ),
            };
        }
    };
}

fn selectorValue(comptime Id: type, value: anytype) Selector(Id) {
    const Value = @TypeOf(value);
    if (comptime Value == Id) return .{ .id = value };
    if (comptime Value == Selector(Id)) return value;
    switch (@typeInfo(Value)) {
        .enum_literal => {
            if (value == .current) return .current;
            @compileError("only .current is a standalone selector literal");
        },
        .@"struct" => {
            if (comptime @hasField(Value, "id")) {
                return .{ .id = @field(value, "id") };
            }
            if (comptime @hasField(Value, "name")) {
                return .{ .name = @field(value, "name") };
            }
            @compileError("selector struct must contain id or name");
        },
        else => @compileError(
            "expected a typed resource ID or Selector(resource ID)",
        ),
    }
}

const HandleRoute = struct {
    machine: ?Selector(MachineId) = null,
    session: ?Selector(SessionId) = null,
    workspace: ?Selector(WorkspaceId) = null,
    screen: ?Selector(ScreenId) = null,
    pane: ?Selector(PaneId) = null,
    tab: ?Selector(TabId) = null,

    fn putSelector(
        comptime Id: type,
        object: *raw.wire.Object,
        allocator: std.mem.Allocator,
        field: []const u8,
        selector: Selector(Id),
    ) !void {
        try object.put(
            try allocator.dupe(u8, field),
            .{ .string = try selector.formatAlloc(allocator) },
        );
    }

    fn putInto(
        self: HandleRoute,
        object: *raw.wire.Object,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.machine) |value| {
            try putSelector(
                MachineId,
                object,
                allocator,
                "machine",
                value,
            );
        }
        if (self.session) |value| {
            try putSelector(
                SessionId,
                object,
                allocator,
                "session",
                value,
            );
        }
        if (self.workspace) |value| {
            try putSelector(
                WorkspaceId,
                object,
                allocator,
                "workspace",
                value,
            );
        }
        if (self.screen) |value| {
            try putSelector(
                ScreenId,
                object,
                allocator,
                "screen",
                value,
            );
        }
        if (self.pane) |value| {
            try putSelector(PaneId, object, allocator, "pane", value);
        }
        if (self.tab) |value| {
            try putSelector(TabId, object, allocator, "tab", value);
        }
    }
};

fn ScopedSelector(comptime Id: type) type {
    return struct {
        selector: Selector(Id),
        ancestors: HandleRoute = .{},
    };
}

pub const MutationOptions = struct {
    bytes: [128]u8 = undefined,
    len: u8,
    expected_revision: ?u64 = null,

    pub fn withKey(provided_key: []const u8) !MutationOptions {
        if (provided_key.len == 0 or provided_key.len > 128) {
            return error.InvalidIdempotencyKey;
        }
        var result: MutationOptions = .{
            .len = @intCast(provided_key.len),
        };
        @memcpy(result.bytes[0..provided_key.len], provided_key);
        return result;
    }

    pub fn random() MutationOptions {
        var entropy: [16]u8 = undefined;
        std.crypto.random.bytes(&entropy);
        var result: MutationOptions = .{ .len = 36 };
        @memcpy(result.bytes[0..4], "zig_");
        const hex = std.fmt.bytesToHex(entropy, .lower);
        @memcpy(result.bytes[4..36], &hex);
        return result;
    }

    pub fn key(self: *const MutationOptions) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn expecting(
        self: MutationOptions,
        revision: u64,
    ) MutationOptions {
        var result = self;
        result.expected_revision = revision;
        return result;
    }
};

pub const ExactCommand = struct {
    argv: []const []const u8,

    pub fn init(argv: []const []const u8) !ExactCommand {
        if (argv.len == 0) return error.InvalidArgv;
        for (argv) |argument| {
            if (argument.len == 0) return error.InvalidArgv;
        }
        return .{ .argv = argv };
    }
};

pub const ShellCommand = struct {
    script: []const u8,
};

pub const RunCommand = union(enum) {
    exact: ExactCommand,
    shell_command: ShellCommand,
    explicit_shell: struct {
        executable: []const u8,
        script: []const u8,
    },

    pub fn argv(values: []const []const u8) !RunCommand {
        return .{ .exact = try ExactCommand.init(values) };
    }

    pub fn shell(script: []const u8) !RunCommand {
        if (script.len == 0) return error.InvalidShellScript;
        return .{ .shell_command = .{ .script = script } };
    }

    /// Encodes as exact `[executable, "-lc", script]`.
    pub fn shellWithExecutable(
        executable: []const u8,
        script: []const u8,
    ) !RunCommand {
        if (executable.len == 0 or script.len == 0) {
            return error.InvalidArgv;
        }
        return .{ .explicit_shell = .{
            .executable = executable,
            .script = script,
        } };
    }
};

pub const InitialContent = enum {
    terminal,
    empty,

    pub fn wireName(self: InitialContent) []const u8 {
        return @tagName(self);
    }
};

pub const Cursor = struct {
    generation: []const u8,
    revision: u64,
};

pub const CreatedWorkspaceOnly = struct {
    workspace_id: WorkspaceId,
};

pub const CreatedTerminalPath = struct {
    workspace_id: WorkspaceId,
    screen_id: ScreenId,
    pane_id: PaneId,
    tab_id: TabId,
    terminal_id: TerminalId,
};

pub const CreatedBrowserPath = struct {
    workspace_id: WorkspaceId,
    screen_id: ScreenId,
    pane_id: PaneId,
    tab_id: TabId,
    browser_id: BrowserId,
};

pub const CreatedPath = union(enum) {
    workspace: CreatedWorkspaceOnly,
    terminal: CreatedTerminalPath,
    browser: CreatedBrowserPath,
};

pub const SensitiveString = struct {
    bytes: []const u8,

    pub fn reveal(self: SensitiveString) []const u8 {
        return self.bytes;
    }

    pub fn format(
        _: SensitiveString,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[REDACTED]");
    }
};

pub const ProviderCredential = SensitiveString;

pub const ResourceError = struct {
    code: []const u8,
    message: []const u8,
    details: ?raw.wire.Value,
    retryable: bool,

    pub fn format(
        self: ResourceError,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "ResourceError{{code={s}, message=[REDACTED], retryable={}}}",
            .{ self.code, self.retryable },
        );
    }
};

pub const OwnedResourceError = struct {
    arena: std.heap.ArenaAllocator,
    value: ResourceError,

    pub fn deinit(self: *OwnedResourceError) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedResult = struct {
    owned: raw.wire.OwnedValue,
    value: raw.wire.Value,

    pub fn deinit(self: *OwnedResult) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

pub const MutationResult = struct {
    value: raw.wire.Value,
    generation: []const u8,
    revision: u64,
    replayed: bool,
    owned: raw.wire.OwnedValue,

    pub fn createdPath(self: *const MutationResult) !?CreatedPath {
        return maybeParseCreatedPath(self.value);
    }

    pub fn deinit(self: *MutationResult) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

pub const RendererGrantOptions = struct {
    endpoint: []const u8,
    terminal_id: TerminalId,
    token: SensitiveString,
    rights: []const []const u8,
    ttl_ms: u32,
};

const RendererGrantStorage = struct {
    allocator: std.mem.Allocator,
    backing: union(enum) {
        offline: std.heap.ArenaAllocator,
        live: struct {
            owned: raw.wire.OwnedValue,
            rights: [][]const u8,
        },
    },
    endpoint: []const u8,
    terminal_id: TerminalId,
    token: SensitiveString,
    rights: []const []const u8,
    ttl_ms: u32,
};

fn validateRendererGrant(options: RendererGrantOptions) !void {
    if (options.endpoint.len == 0) return error.InvalidRendererEndpoint;
    if (options.token.reveal().len == 0) {
        return error.InvalidRendererToken;
    }
    if (options.rights.len == 0) return error.MissingRendererRight;
    for (options.rights) |right| {
        if (right.len == 0) return error.InvalidRendererRight;
    }
    if (options.ttl_ms == 0 or options.ttl_ms > 60_000) {
        return error.InvalidRendererTtl;
    }
}

/// Owned one-use renderer credential. Only accessor methods expose data, so
/// allocator and response ownership cannot be forged by aggregate literals.
pub const RendererGrant = opaque {
    fn storage(self: *const RendererGrant) *const RendererGrantStorage {
        return @ptrCast(@alignCast(self));
    }

    fn storageMut(self: *RendererGrant) *RendererGrantStorage {
        return @ptrCast(@alignCast(self));
    }

    /// Creates a validated, independently owned grant for offline tooling and
    /// tests. All input slices may be released after this call returns.
    pub fn init(
        allocator: std.mem.Allocator,
        options: RendererGrantOptions,
    ) !*RendererGrant {
        try validateRendererGrant(options);
        const state = try allocator.create(RendererGrantStorage);
        errdefer allocator.destroy(state);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const owned_rights = try owned.alloc(
            []const u8,
            options.rights.len,
        );
        for (options.rights, 0..) |right, index| {
            owned_rights[index] = try owned.dupe(u8, right);
        }
        state.* = .{
            .allocator = allocator,
            .backing = .{ .offline = arena },
            .endpoint = try owned.dupe(u8, options.endpoint),
            .terminal_id = options.terminal_id,
            .token = .{
                .bytes = try owned.dupe(u8, options.token.reveal()),
            },
            .rights = owned_rights,
            .ttl_ms = options.ttl_ms,
        };
        return @ptrCast(state);
    }

    fn initLive(
        allocator: std.mem.Allocator,
        owned: raw.wire.OwnedValue,
        options: RendererGrantOptions,
        live_rights: [][]const u8,
    ) !*RendererGrant {
        try validateRendererGrant(options);
        const state = try allocator.create(RendererGrantStorage);
        state.* = .{
            .allocator = allocator,
            .backing = .{ .live = .{
                .owned = owned,
                .rights = live_rights,
            } },
            .endpoint = options.endpoint,
            .terminal_id = options.terminal_id,
            .token = options.token,
            .rights = live_rights,
            .ttl_ms = options.ttl_ms,
        };
        return @ptrCast(state);
    }

    pub fn deinit(self: *RendererGrant) void {
        const state = self.storageMut();
        if (state.token.bytes.len > 0) {
            @memset(@constCast(state.token.bytes), 0);
        }
        const allocator = state.allocator;
        switch (state.backing) {
            .offline => |*arena| arena.deinit(),
            .live => |*live| {
                allocator.free(live.rights);
                live.owned.deinit();
            },
        }
        allocator.destroy(state);
    }

    pub fn endpoint(self: *const RendererGrant) []const u8 {
        return self.storage().endpoint;
    }

    pub fn terminalId(self: *const RendererGrant) TerminalId {
        return self.storage().terminal_id;
    }

    pub fn token(self: *const RendererGrant) SensitiveString {
        return self.storage().token;
    }

    pub fn rights(self: *const RendererGrant) []const []const u8 {
        return self.storage().rights;
    }

    pub fn ttlMs(self: *const RendererGrant) u32 {
        return self.storage().ttl_ms;
    }

    pub fn format(
        _: *const RendererGrant,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("RendererGrant{token=[REDACTED]}");
    }
};

pub const ConnectionFactory = struct {
    context: *anyopaque,
    openFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) anyerror!raw.transport.Connection,

    pub fn open(
        self: ConnectionFactory,
        allocator: std.mem.Allocator,
    ) !raw.transport.Connection {
        return self.openFn(self.context, allocator);
    }
};

pub const Options = struct {
    session: []const u8 = "main",
    socket_path: ?[]const u8 = null,
    timeout_ms: ?u32 = 10_000,
    limits: raw.wire.Limits = .{},
    stream_factory: ?ConnectionFactory = null,
};

fn isSecretField(key: []const u8) bool {
    return std.mem.eql(u8, key, "token") or
        std.mem.eql(u8, key, "specifier") or
        std.mem.eql(u8, key, "credential") or
        std.mem.eql(u8, key, "secret") or
        std.mem.eql(u8, key, "provider_credential") or
        std.mem.eql(u8, key, "authority_secret");
}

fn cloneRedacted(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !raw.wire.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .integer => |item| .{ .integer = item },
        .float => |item| .{ .float = item },
        .number_string => |item| .{
            .number_string = try allocator.dupe(u8, item),
        },
        .string => |item| .{ .string = try allocator.dupe(u8, item) },
        .array => |items| blk: {
            var result = std.json.Array.init(allocator);
            for (items.items) |item| {
                try result.append(try cloneRedacted(allocator, item));
            }
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result = raw.wire.Object.init(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const redacted: raw.wire.Value = if (isSecretField(key))
                    .{ .string = try allocator.dupe(u8, "[REDACTED]") }
                else
                    try cloneRedacted(allocator, entry.value_ptr.*);
                try result.put(key, redacted);
            }
            break :blk .{ .object = result };
        },
    };
}

fn decimalU64(value: raw.wire.Value) !u64 {
    return switch (value) {
        .number_string => |text| std.fmt.parseInt(u64, text, 10),
        .string => |text| std.fmt.parseInt(u64, text, 10),
        .integer => |number| std.math.cast(u64, number) orelse
            error.IntegerOverflow,
        else => error.ExpectedDecimalString,
    };
}

fn objectString(
    object: raw.wire.Object,
    name: []const u8,
) ![]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn parseRequiredId(
    comptime Id: type,
    object: raw.wire.Object,
    name: []const u8,
) !Id {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| try Id.parse(text),
        else => error.ExpectedString,
    };
}

fn parseCreatedPath(value: raw.wire.Value) !CreatedPath {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "workspace")) {
        return .{ .workspace = .{
            .workspace_id = try parseRequiredId(
                WorkspaceId,
                object,
                "workspace_id",
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "terminal")) {
        return .{ .terminal = .{
            .workspace_id = try parseRequiredId(
                WorkspaceId,
                object,
                "workspace_id",
            ),
            .screen_id = try parseRequiredId(
                ScreenId,
                object,
                "screen_id",
            ),
            .pane_id = try parseRequiredId(PaneId, object, "pane_id"),
            .tab_id = try parseRequiredId(TabId, object, "tab_id"),
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "browser")) {
        return .{ .browser = .{
            .workspace_id = try parseRequiredId(
                WorkspaceId,
                object,
                "workspace_id",
            ),
            .screen_id = try parseRequiredId(
                ScreenId,
                object,
                "screen_id",
            ),
            .pane_id = try parseRequiredId(PaneId, object, "pane_id"),
            .tab_id = try parseRequiredId(TabId, object, "tab_id"),
            .browser_id = try parseRequiredId(
                BrowserId,
                object,
                "browser_id",
            ),
        } };
    }
    return error.UnknownCreatedPathKind;
}

fn maybeParseCreatedPath(value: raw.wire.Value) !?CreatedPath {
    const object = switch (value) {
        .object => |item| item,
        else => return null,
    };
    const kind_value = object.get("kind") orelse return null;
    const kind = switch (kind_value) {
        .string => |text| text,
        else => return null,
    };
    if (!std.mem.eql(u8, kind, "workspace") and
        !std.mem.eql(u8, kind, "terminal") and
        !std.mem.eql(u8, kind, "browser"))
    {
        return null;
    }
    return try parseCreatedPath(value);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection: raw.transport.Connection,
    timeout_ms: ?u32,
    limits: raw.wire.Limits,
    stream_factory: ?ConnectionFactory,
    owned_socket_path: ?[]u8 = null,
    inbound: std.ArrayList(u8) = .empty,
    next_request_id: u64 = 1,
    closed: bool = false,
    mutex: std.Thread.Mutex = .{},
    close_mutex: std.Thread.Mutex = .{},
    last_error: ?OwnedResourceError = null,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: raw.transport.Connection,
        options: Options,
    ) Client {
        return .{
            .allocator = allocator,
            .connection = connection,
            .timeout_ms = options.timeout_ms,
            .limits = options.limits,
            .stream_factory = options.stream_factory,
        };
    }

    pub fn connect(
        allocator: std.mem.Allocator,
        options: Options,
    ) !Client {
        const path = try raw.transport.resolveSocketPath(
            allocator,
            options.socket_path,
            options.session,
        );
        errdefer allocator.free(path);
        var connection = try raw.transport.connectUnix(allocator, path);
        errdefer connection.deinit();
        var result = init(allocator, connection, options);
        result.owned_socket_path = path;
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
        self.clearError();
        if (self.owned_socket_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn lastResourceError(self: *const Client) ?ResourceError {
        return if (self.last_error) |failure| failure.value else null;
    }

    pub fn takeResourceError(self: *Client) ?OwnedResourceError {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.last_error orelse return null;
        self.last_error = null;
        return result;
    }

    fn clearError(self: *Client) void {
        if (self.last_error) |*failure| failure.deinit();
        self.last_error = null;
    }

    fn setError(self: *Client, value: raw.wire.Value) !void {
        self.clearError();
        const object = switch (value) {
            .object => |item| item,
            else => return error.InvalidResourceError,
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const code = try allocator.dupe(
            u8,
            objectString(object, "code") catch "protocol.error",
        );
        const message = try allocator.dupe(
            u8,
            objectString(object, "message") catch "cmux operation failed",
        );
        const details = if (object.get("details")) |details_value|
            try cloneRedacted(allocator, details_value)
        else
            null;
        const retryable = if (object.get("retryable")) |retryable_value|
            switch (retryable_value) {
                .bool => |item| item,
                else => false,
            }
        else
            false;
        self.last_error = .{
            .arena = arena,
            .value = .{
                .code = code,
                .message = message,
                .details = details,
                .retryable = retryable,
            },
        };
    }

    fn requestId(self: *Client) ![]u8 {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id == 0) self.next_request_id = 1;
        return std.fmt.allocPrint(
            self.allocator,
            "zig-request-{d}",
            .{id},
        );
    }

    fn sendRequest(
        self: *Client,
        request_id: []const u8,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
    ) !void {
        if (self.closed) return error.ConnectionClosed;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var envelope = raw.wire.Object.init(allocator);
        var routed_params = switch (try raw.wire.cloneValue(
            allocator,
            params,
        )) {
            .object => |value| value,
            else => return error.ExpectedObject,
        };
        if (operation.requiresMachine() and
            routed_params.get("machine") == null)
        {
            try routed_params.put(
                try allocator.dupe(u8, "machine"),
                .{ .string = try allocator.dupe(u8, "current") },
            );
        }
        if (operation.requiresSession() and
            routed_params.get("session") == null)
        {
            try routed_params.put(
                try allocator.dupe(u8, "session"),
                .{ .string = try allocator.dupe(u8, "current") },
            );
        }
        if (mutation) |options| {
            if (options.expected_revision) |revision| {
                if (!operation.supportsExpectedRevision()) {
                    return error.UnsupportedRevisionPrecondition;
                }
                try routed_params.put(
                    try allocator.dupe(u8, "expected_revision"),
                    .{ .string = try std.fmt.allocPrint(
                        allocator,
                        "{d}",
                        .{revision},
                    ) },
                );
            }
        }
        try envelope.put(
            "protocol",
            .{ .string = try allocator.dupe(u8, "cmux.protocol/1") },
        );
        try envelope.put(
            "type",
            .{ .string = try allocator.dupe(u8, "request") },
        );
        try envelope.put(
            "id",
            .{ .string = try allocator.dupe(u8, request_id) },
        );
        try envelope.put(
            "operation",
            .{ .string = try allocator.dupe(u8, operation.wireName()) },
        );
        try envelope.put(
            "params",
            .{ .object = routed_params },
        );
        if (mutation) |options| {
            try envelope.put(
                "idempotency_key",
                .{ .string = try allocator.dupe(u8, options.key()) },
            );
        }
        const encoded = try raw.wire.stringifyAlloc(
            self.allocator,
            .{ .object = envelope },
        );
        defer self.allocator.free(encoded);
        if (encoded.len > self.limits.max_request_bytes) {
            return error.RequestTooLarge;
        }
        try self.connection.writeAll(encoded, self.timeout_ms);
        try self.connection.writeAll("\n", self.timeout_ms);
    }

    fn takeFrame(self: *Client) !?[]u8 {
        const newline = std.mem.indexOfScalar(
            u8,
            self.inbound.items,
            '\n',
        ) orelse {
            if (self.inbound.items.len > self.limits.max_frame_bytes) {
                return error.FrameTooLarge;
            }
            return null;
        };
        if (newline > self.limits.max_frame_bytes) {
            return error.FrameTooLarge;
        }
        const line_end = if (newline > 0 and
            self.inbound.items[newline - 1] == '\r')
            newline - 1
        else
            newline;
        const line = try self.allocator.dupe(
            u8,
            self.inbound.items[0..line_end],
        );
        const consumed = newline + 1;
        std.mem.copyForwards(
            u8,
            self.inbound.items[0 .. self.inbound.items.len - consumed],
            self.inbound.items[consumed..],
        );
        self.inbound.items.len -= consumed;
        return line;
    }

    fn readMessage(self: *Client) !raw.wire.OwnedValue {
        while (true) {
            if (try self.takeFrame()) |frame| {
                defer self.allocator.free(frame);
                if (frame.len == 0) return error.EmptyFrame;
                return raw.wire.parse(self.allocator, frame, self.limits);
            }
            var chunk: [8192]u8 = undefined;
            const count = try self.connection.read(&chunk, self.timeout_ms);
            if (count == 0) return error.ConnectionClosed;
            try self.inbound.appendSlice(
                self.allocator,
                chunk[0..count],
            );
        }
    }

    fn callLocked(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
    ) !OwnedResult {
        self.clearError();
        const request_id = try self.requestId();
        defer self.allocator.free(request_id);
        try self.sendRequest(request_id, operation, params, mutation);
        while (true) {
            var message = try self.readMessage();
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const protocol = objectString(object, "protocol") catch {
                return error.InvalidProtocolEnvelope;
            };
            if (!std.mem.eql(u8, protocol, "cmux.protocol/1")) {
                return error.InvalidProtocolEnvelope;
            }
            const envelope_type = objectString(object, "type") catch {
                return error.InvalidProtocolEnvelope;
            };
            if (!std.mem.eql(u8, envelope_type, "response")) {
                message.deinit();
                continue;
            }
            const response_id = objectString(object, "id") catch {
                message.deinit();
                continue;
            };
            if (!std.mem.eql(u8, response_id, request_id)) {
                message.deinit();
                continue;
            }
            const ok = switch (object.get("ok") orelse
                return error.MissingResponseStatus) {
                .bool => |item| item,
                else => return error.InvalidResponseStatus,
            };
            if (!ok) {
                try self.setError(
                    object.get("error") orelse
                        return error.InvalidResourceError,
                );
                return error.RemoteError;
            }
            const result = object.get("result") orelse
                return error.MissingResponseResult;
            return .{ .owned = message, .value = result };
        }
    }

    fn callClass(
        self: *Client,
        expected: OperationClass,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
    ) !OwnedResult {
        if (operation.class() != expected) return error.WrongOperationClass;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.callLocked(operation, params, mutation);
    }

    pub fn read(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
    ) !OwnedResult {
        return self.callClass(.read, operation, params, null);
    }

    pub fn control(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
    ) !OwnedResult {
        return self.callClass(
            .connection_control,
            operation,
            params,
            null,
        );
    }

    pub fn mutate(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
        options: MutationOptions,
    ) !MutationResult {
        var result = try self.callClass(
            .mutation,
            operation,
            params,
            options,
        );
        errdefer result.deinit();
        const object = switch (result.value) {
            .object => |item| item,
            else => return error.ExpectedObject,
        };
        const generation = try objectString(object, "generation");
        if (generation.len == 0 or generation.len > 128) {
            return error.InvalidMutationGeneration;
        }
        const revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        );
        const replayed = switch (object.get("replayed") orelse
            return error.MissingField) {
            .bool => |value| value,
            else => return error.ExpectedBool,
        };
        const logical_value = object.get("value") orelse
            return error.MissingMutationValue;
        const mutation_result = MutationResult{
            .value = logical_value,
            .generation = generation,
            .revision = revision,
            .replayed = replayed,
            .owned = result.owned,
        };
        result = undefined;
        return mutation_result;
    }

    fn streamConnection(self: *Client) !raw.transport.Connection {
        if (self.stream_factory) |factory| {
            return factory.open(self.allocator);
        }
        const path = self.owned_socket_path orelse
            return error.StreamConnectionUnavailable;
        return raw.transport.connectUnix(self.allocator, path);
    }

    fn streamOptions(self: *const Client) Options {
        return .{
            .timeout_ms = self.timeout_ms,
            .limits = self.limits,
            .stream_factory = self.stream_factory,
        };
    }

    pub fn openSessionEvents(
        self: *Client,
        params: raw.wire.Value,
    ) !SessionEventStream {
        const connection = try self.streamConnection();
        return self.openSessionEventsOn(connection, params);
    }

    pub fn openSessionEventsOn(
        self: *Client,
        connection: raw.transport.Connection,
        params: raw.wire.Value,
    ) !SessionEventStream {
        return .{ .raw_stream = try RawStream.open(
            self.allocator,
            connection,
            self.streamOptions(),
            .session_events,
            params,
        ) };
    }

    pub fn openTerminalAttachment(
        self: *Client,
        params: raw.wire.Value,
    ) !TerminalAttachmentStream {
        const connection = try self.streamConnection();
        return .{ .raw_stream = try RawStream.open(
            self.allocator,
            connection,
            self.streamOptions(),
            .terminal_attach,
            params,
        ) };
    }

    pub fn openBrowserAttachment(
        self: *Client,
        params: raw.wire.Value,
    ) !BrowserAttachmentStream {
        const connection = try self.streamConnection();
        return .{ .raw_stream = try RawStream.open(
            self.allocator,
            connection,
            self.streamOptions(),
            .browser_attach,
            params,
        ) };
    }

    pub fn openSidebarView(
        self: *Client,
        params: raw.wire.Value,
    ) !SidebarViewStream {
        const connection = try self.streamConnection();
        return .{ .raw_stream = try RawStream.open(
            self.allocator,
            connection,
            self.streamOptions(),
            .sidebar_view_attach,
            params,
        ) };
    }

    pub fn openProviderNotices(
        self: *Client,
        params: raw.wire.Value,
    ) !ProviderNoticeStream {
        const connection = try self.streamConnection();
        return .{ .raw_stream = try RawStream.open(
            self.allocator,
            connection,
            self.streamOptions(),
            .provider_notice_events,
            params,
        ) };
    }

    pub fn machine(self: *Client, selector: anytype) Machine {
        return Machine.init(self, selector);
    }

    pub fn session(self: *Client, selector: anytype) Session {
        return Session.initScoped(self, selector, .{
            .machine = .current,
        });
    }

    pub fn workspace(self: *Client, selector: anytype) Workspace {
        return Workspace.initScoped(self, selector, .{
            .machine = .current,
            .session = .current,
        });
    }

    pub fn screen(self: *Client, selector: anytype) Screen {
        const selection = selectorValue(ScreenId, selector);
        var route = HandleRoute{
            .machine = .current,
            .session = .current,
        };
        switch (selection) {
            .id => {},
            .current, .name => route.workspace = .current,
        }
        return Screen.initScoped(self, selection, route);
    }

    pub fn pane(self: *Client, selector: anytype) Pane {
        const selection = selectorValue(PaneId, selector);
        var route = HandleRoute{
            .machine = .current,
            .session = .current,
        };
        switch (selection) {
            .id => {},
            .current, .name => {
                route.workspace = .current;
                route.screen = .current;
            },
        }
        return Pane.initScoped(self, selection, route);
    }

    pub fn tab(self: *Client, selector: anytype) Tab {
        const selection = selectorValue(TabId, selector);
        var route = HandleRoute{
            .machine = .current,
            .session = .current,
        };
        switch (selection) {
            .id => {},
            .current, .name => {
                route.workspace = .current;
                route.screen = .current;
                route.pane = .current;
            },
        }
        return Tab.initScoped(self, selection, route);
    }

    pub fn terminal(self: *Client, selector: anytype) Terminal {
        const selection = selectorValue(TerminalId, selector);
        var route = HandleRoute{
            .machine = .current,
            .session = .current,
        };
        switch (selection) {
            .id => {},
            .current, .name => {
                route.workspace = .current;
                route.screen = .current;
                route.pane = .current;
                route.tab = .current;
            },
        }
        return Terminal.initScoped(self, selection, route);
    }

    pub fn browser(self: *Client, selector: anytype) Browser {
        const selection = selectorValue(BrowserId, selector);
        var route = HandleRoute{
            .machine = .current,
            .session = .current,
        };
        switch (selection) {
            .id => {},
            .current, .name => {
                route.workspace = .current;
                route.screen = .current;
                route.pane = .current;
                route.tab = .current;
            },
        }
        return Browser.initScoped(self, selection, route);
    }

    pub fn connectedClient(
        self: *Client,
        id: ConnectedClientId,
    ) ConnectedClient {
        return ConnectedClient.init(self, id);
    }

    pub fn sidebarView(self: *Client, id: SidebarViewId) SidebarView {
        return SidebarView.init(self, id);
    }

    pub fn providerScope(
        self: *Client,
        id: ProviderScopeId,
    ) ProviderScope {
        return ProviderScope.init(self, id);
    }

    pub fn providerAction(
        self: *Client,
        id: ProviderActionId,
    ) ProviderAction {
        return ProviderAction.init(self, id);
    }

    pub fn providerNotice(
        self: *Client,
        id: ProviderNoticeId,
    ) ProviderNoticeHandle {
        return ProviderNoticeHandle.init(self, id);
    }

    pub fn machines(self: *Client) !OwnedResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return self.read(
            .machine_list,
            .{ .object = raw.wire.Object.init(arena.allocator()) },
        );
    }

    pub fn invokeProviderAction(
        self: *Client,
        scope: ProviderScopeId,
        action: ProviderActionId,
        parameters: raw.wire.Object,
        options: MutationOptions,
    ) !MutationResult {
        var params = try Params(ProviderActionId).init(
            self.allocator,
            "provider_action",
            &action,
            null,
        );
        defer params.deinit();
        try params.putString("provider_scope", scope.slice());
        try params.putValue("parameters", .{ .object = parameters });
        return self.mutate(
            .provider_action_invoke,
            params.asValue(),
            options,
        );
    }
};

pub const StreamEndReason = enum {
    completed,
    canceled,
    closed,
    gap,
    @"error",
};

pub const StreamEnd = struct {
    reason: StreamEndReason,
    cursor: ?Cursor = null,
    recovery: ?[]const u8 = null,
    resource_error: ?ResourceError = null,
};

pub const ResetReason = enum {
    initial,
    generation_changed,
    cursor_expired,
};

pub const ResourceKind = enum {
    machine,
    session,
    workspace,
    screen,
    pane,
    tab,
    terminal,
    browser,
    client,
    notification,
    agent,
    pairing_request,
    frontend_projection,
    sidebar_view,
    provider_scope,
    provider_action,
    provider_notice,

    fn parse(value: []const u8) !ResourceKind {
        inline for (@typeInfo(ResourceKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.UnknownResourceKind;
    }
};

pub const ResourceReference = union(ResourceKind) {
    machine: MachineId,
    session: SessionId,
    workspace: WorkspaceId,
    screen: ScreenId,
    pane: PaneId,
    tab: TabId,
    terminal: TerminalId,
    browser: BrowserId,
    client: ConnectedClientId,
    notification: NotificationId,
    agent: AgentId,
    pairing_request: PairingRequestId,
    frontend_projection: FrontendProjectionId,
    sidebar_view: SidebarViewId,
    provider_scope: ProviderScopeId,
    provider_action: ProviderActionId,
    provider_notice: ProviderNoticeId,

    pub fn slice(self: *const ResourceReference) []const u8 {
        return switch (self.*) {
            inline else => |*id| id.slice(),
        };
    }
};

pub const UnknownDiscriminated = struct {
    discriminator: []const u8,
    raw_object: raw.wire.Value,
};

pub const ResourceUpsert = struct {
    sequence: u32,
    resource: ResourceKind,
    id: ResourceReference,
    value: raw.wire.Value,
};

pub const ResourceDelete = struct {
    sequence: u32,
    resource: ResourceKind,
    id: ResourceReference,
};

pub const ResourceChange = union(enum) {
    upsert: ResourceUpsert,
    delete: ResourceDelete,
    unknown: UnknownDiscriminated,
};

pub const SessionSnapshotEvent = struct {
    cursor: Cursor,
    reset_reason: ?ResetReason,
    snapshot: raw.wire.Value,
};

pub const SessionDeltaEvent = struct {
    cursor: Cursor,
    previous_revision: u64,
    revision: u64,
    changes: []ResourceChange,
};

pub const SessionEvent = union(enum) {
    snapshot: SessionSnapshotEvent,
    delta: SessionDeltaEvent,
    unknown: UnknownDiscriminated,
};

pub const TerminalAttachmentItem = struct {
    kind: []const u8,
    data: raw.wire.Value,
    extra: raw.wire.Value,
};

pub const BrowserAttachmentItem = struct {
    kind: []const u8,
    data: raw.wire.Value,
    extra: raw.wire.Value,
};

pub const SidebarViewItem = struct {
    kind: []const u8,
    data: raw.wire.Value,
    extra: raw.wire.Value,
};

pub const ProviderNotice = struct {
    kind: []const u8,
    data: raw.wire.Value,
    extra: raw.wire.Value,
};

fn parseCursor(value: raw.wire.Value) !Cursor {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    return .{
        .generation = try objectString(object, "generation"),
        .revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        ),
    };
}

fn ensureOnlyFields(
    object: raw.wire.Object,
    allowed: []const []const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.UnexpectedField;
    }
}

fn parseStrictCursor(value: raw.wire.Value) !Cursor {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    try ensureOnlyFields(object, &.{ "generation", "revision" });
    const cursor = try parseCursor(value);
    if (cursor.generation.len == 0 or cursor.generation.len > 128) {
        return error.InvalidCursorGeneration;
    }
    return cursor;
}

fn validateEnvelopeCursor(
    envelope: ?Cursor,
    item: Cursor,
) !void {
    const expected = envelope orelse return;
    if (!std.mem.eql(u8, expected.generation, item.generation) or
        expected.revision != item.revision)
    {
        return error.StreamCursorMismatch;
    }
}

fn parseResourceReference(
    resource: ResourceKind,
    value: []const u8,
) !ResourceReference {
    return switch (resource) {
        .machine => .{ .machine = try MachineId.parse(value) },
        .session => .{ .session = try SessionId.parse(value) },
        .workspace => .{ .workspace = try WorkspaceId.parse(value) },
        .screen => .{ .screen = try ScreenId.parse(value) },
        .pane => .{ .pane = try PaneId.parse(value) },
        .tab => .{ .tab = try TabId.parse(value) },
        .terminal => .{ .terminal = try TerminalId.parse(value) },
        .browser => .{ .browser = try BrowserId.parse(value) },
        .client => .{ .client = try ConnectedClientId.parse(value) },
        .notification => .{
            .notification = try NotificationId.parse(value),
        },
        .agent => .{ .agent = try AgentId.parse(value) },
        .pairing_request => .{
            .pairing_request = try PairingRequestId.parse(value),
        },
        .frontend_projection => .{
            .frontend_projection = try FrontendProjectionId.parse(
                value,
            ),
        },
        .sidebar_view => .{
            .sidebar_view = try SidebarViewId.parse(value),
        },
        .provider_scope => .{
            .provider_scope = try ProviderScopeId.parse(value),
        },
        .provider_action => .{
            .provider_action = try ProviderActionId.parse(value),
        },
        .provider_notice => .{
            .provider_notice = try ProviderNoticeId.parse(value),
        },
    };
}

fn decodeResourceChange(value: raw.wire.Value) !ResourceChange {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const kind = try objectString(object, "kind");
    if (!std.mem.eql(u8, kind, "upsert") and
        !std.mem.eql(u8, kind, "delete"))
    {
        return .{ .unknown = .{
            .discriminator = kind,
            .raw_object = value,
        } };
    }
    const sequence_u64 = try decimalU64(
        object.get("sequence") orelse return error.MissingField,
    );
    const sequence = std.math.cast(u32, sequence_u64) orelse
        return error.IntegerOverflow;
    const resource = try ResourceKind.parse(
        try objectString(object, "resource"),
    );
    const id = try parseResourceReference(
        resource,
        try objectString(object, "id"),
    );
    if (std.mem.eql(u8, kind, "delete")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "sequence", "resource", "id" },
        );
        return .{ .delete = .{
            .sequence = sequence,
            .resource = resource,
            .id = id,
        } };
    }
    try ensureOnlyFields(
        object,
        &.{ "kind", "sequence", "resource", "id", "value" },
    );
    const snapshot = object.get("value") orelse return error.MissingField;
    const snapshot_object = switch (snapshot) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const snapshot_id = try objectString(snapshot_object, "id");
    if (!std.mem.eql(u8, id.slice(), snapshot_id)) {
        return error.ResourceSnapshotIdMismatch;
    }
    return .{ .upsert = .{
        .sequence = sequence,
        .resource = resource,
        .id = id,
        .value = snapshot,
    } };
}

fn decodeSessionEvent(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
    envelope_cursor: ?Cursor,
) !SessionEvent {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "snapshot")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "cursor", "reset_reason", "snapshot" },
        );
        const cursor = try parseStrictCursor(
            object.get("cursor") orelse return error.MissingField,
        );
        try validateEnvelopeCursor(envelope_cursor, cursor);
        const reset_reason = if (object.get("reset_reason")) |reason|
            switch (reason) {
                .string => |text| blk: {
                    if (std.mem.eql(u8, text, "initial")) {
                        break :blk ResetReason.initial;
                    }
                    if (std.mem.eql(u8, text, "generation_changed")) {
                        break :blk ResetReason.generation_changed;
                    }
                    if (std.mem.eql(u8, text, "cursor_expired")) {
                        break :blk ResetReason.cursor_expired;
                    }
                    return error.InvalidResetReason;
                },
                else => return error.ExpectedString,
            }
        else
            null;
        const snapshot = object.get("snapshot") orelse
            return error.MissingField;
        switch (snapshot) {
            .object => {},
            else => return error.ExpectedObject,
        }
        return .{ .snapshot = .{
            .cursor = cursor,
            .reset_reason = reset_reason,
            .snapshot = snapshot,
        } };
    }
    if (std.mem.eql(u8, kind, "delta")) {
        try ensureOnlyFields(
            object,
            &.{
                "kind",
                "cursor",
                "previous_revision",
                "revision",
                "changes",
            },
        );
        const cursor = try parseStrictCursor(
            object.get("cursor") orelse return error.MissingField,
        );
        try validateEnvelopeCursor(envelope_cursor, cursor);
        const previous_revision = try decimalU64(
            object.get("previous_revision") orelse
                return error.MissingField,
        );
        const revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        );
        if (revision != cursor.revision) {
            return error.StreamCursorMismatch;
        }
        const raw_changes = switch (object.get("changes") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        const changes = try allocator.alloc(
            ResourceChange,
            raw_changes.len,
        );
        for (raw_changes, 0..) |change, index| {
            changes[index] = try decodeResourceChange(change);
        }
        return .{ .delta = .{
            .cursor = cursor,
            .previous_revision = previous_revision,
            .revision = revision,
            .changes = changes,
        } };
    }
    return .{ .unknown = .{
        .discriminator = kind,
        .raw_object = value,
    } };
}

fn domainItem(
    comptime Item: type,
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
    cursor: ?Cursor,
) !Item {
    if (comptime Item == SessionEvent) {
        return decodeSessionEvent(allocator, value, cursor);
    }
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const kind = if (object.get("event")) |event|
        switch (event) {
            .string => |item| item,
            else => return error.ExpectedString,
        }
    else if (object.get("type")) |item_type|
        switch (item_type) {
            .string => |item| item,
            else => return error.ExpectedString,
        }
    else if (object.get("kind")) |named_kind|
        switch (named_kind) {
            .string => |item| item,
            else => return error.ExpectedString,
        }
    else
        "unknown";
    return .{
        .kind = kind,
        .data = object.get("data") orelse value,
        .extra = value,
    };
}

fn OwnedStreamItem(comptime Item: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        decoded: std.heap.ArenaAllocator,
        sequence: u64,
        cursor: ?Cursor,
        value: Item,

        pub fn deinit(self: *Self) void {
            self.decoded.deinit();
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn streamId() StreamId {
    var entropy: [16]u8 = undefined;
    std.crypto.random.bytes(&entropy);
    const hex = std.fmt.bytesToHex(entropy, .lower);
    var bytes: [StreamId.encoded_len]u8 = undefined;
    @memcpy(bytes[0.."stream_".len], "stream_");
    @memcpy(bytes["stream_".len..], &hex);
    return .{ .bytes = bytes };
}

fn parseStreamEndReason(value: []const u8) !StreamEndReason {
    if (std.mem.eql(u8, value, "completed")) return .completed;
    if (std.mem.eql(u8, value, "canceled")) return .canceled;
    if (std.mem.eql(u8, value, "closed")) return .closed;
    if (std.mem.eql(u8, value, "gap")) return .gap;
    if (std.mem.eql(u8, value, "error")) return .@"error";
    return error.UnknownStreamEndReason;
}

fn ownedErrorFromValue(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !OwnedResourceError {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidResourceError,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned_allocator = arena.allocator();
    const code = try owned_allocator.dupe(
        u8,
        objectString(object, "code") catch "stream.error",
    );
    const message = try owned_allocator.dupe(
        u8,
        objectString(object, "message") catch "cmux stream failed",
    );
    const details = if (object.get("details")) |details_value|
        try cloneRedacted(owned_allocator, details_value)
    else
        null;
    const retryable = if (object.get("retryable")) |retryable_value|
        switch (retryable_value) {
            .bool => |item| item,
            else => false,
        }
    else
        false;
    return .{
        .arena = arena,
        .value = .{
            .code = code,
            .message = message,
            .details = details,
            .retryable = retryable,
        },
    };
}

const RawStream = struct {
    client: Client,
    stream_id: StreamId,
    machine_selector: []u8,
    session_selector: []u8,
    pending: std.ArrayList(raw.wire.OwnedValue) = .empty,
    end_frame: ?raw.wire.OwnedValue = null,
    end_error: ?OwnedResourceError = null,
    stream_end: ?StreamEnd = null,
    deinitialized: bool = false,

    fn open(
        allocator: std.mem.Allocator,
        connection: raw.transport.Connection,
        options: Options,
        operation: Operation,
        params: raw.wire.Value,
    ) !RawStream {
        if (operation.class() != .stream_open) {
            return error.WrongOperationClass;
        }
        var stream_client = Client.init(allocator, connection, options);
        errdefer stream_client.deinit();
        const id = streamId();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var object = switch (try raw.wire.cloneValue(temp, params)) {
            .object => |item| item,
            else => return error.ExpectedObject,
        };
        try object.put(
            "stream_id",
            .{ .string = try temp.dupe(u8, id.slice()) },
        );
        const machine_selector = if (object.get("machine")) |value|
            switch (value) {
                .string => |item| item,
                else => return error.ExpectedString,
            }
        else
            "current";
        const session_selector = if (object.get("session")) |value|
            switch (value) {
                .string => |item| item,
                else => return error.ExpectedString,
            }
        else
            "current";
        const owned_machine = try allocator.dupe(u8, machine_selector);
        errdefer allocator.free(owned_machine);
        const owned_session = try allocator.dupe(u8, session_selector);
        errdefer allocator.free(owned_session);
        var opened = try stream_client.callClass(
            .stream_open,
            operation,
            .{ .object = object },
            null,
        );
        opened.deinit();
        return .{
            .client = stream_client,
            .stream_id = id,
            .machine_selector = owned_machine,
            .session_selector = owned_session,
        };
    }

    fn deinit(self: *RawStream) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.client.close();
        for (self.pending.items) |*message| message.deinit();
        self.pending.deinit(self.client.allocator);
        if (self.end_frame) |*frame| frame.deinit();
        if (self.end_error) |*failure| failure.deinit();
        self.client.allocator.free(self.machine_selector);
        self.client.allocator.free(self.session_selector);
        self.client.deinit();
        self.* = undefined;
    }

    fn envelopeForThisStream(
        self: *const RawStream,
        object: raw.wire.Object,
    ) bool {
        const value = object.get("stream_id") orelse return false;
        const encoded = switch (value) {
            .string => |item| item,
            else => return false,
        };
        return std.mem.eql(u8, encoded, self.stream_id.slice());
    }

    fn storeEnd(
        self: *RawStream,
        message: raw.wire.OwnedValue,
    ) !void {
        if (self.stream_end != null) {
            var duplicate = message;
            duplicate.deinit();
            return;
        }
        const object = switch (message.value) {
            .object => |item| item,
            else => return error.ExpectedObject,
        };
        const reason = try parseStreamEndReason(
            try objectString(object, "reason"),
        );
        const cursor = if (object.get("cursor")) |cursor_value|
            switch (cursor_value) {
                .null => null,
                else => try parseCursor(cursor_value),
            }
        else
            null;
        const recovery = if (object.get("recovery")) |recovery_value|
            switch (recovery_value) {
                .null => null,
                .string => |item| item,
                else => null,
            }
        else
            null;
        if (object.get("error")) |error_value| {
            switch (error_value) {
                .null => {},
                else => self.end_error = try ownedErrorFromValue(
                    self.client.allocator,
                    error_value,
                ),
            }
        }
        self.end_frame = message;
        self.stream_end = .{
            .reason = reason,
            .cursor = cursor,
            .recovery = recovery,
            .resource_error = if (self.end_error) |failure|
                failure.value
            else
                null,
        };
    }

    fn nextRaw(
        self: *RawStream,
    ) !?raw.wire.OwnedValue {
        if (self.stream_end != null) return null;
        while (true) {
            var message = if (self.pending.items.len > 0)
                self.pending.orderedRemove(0)
            else
                try self.client.readMessage();
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            if (!self.envelopeForThisStream(object)) {
                message.deinit();
                continue;
            }
            const envelope_type = try objectString(object, "type");
            if (std.mem.eql(u8, envelope_type, "stream_end")) {
                try self.storeEnd(message);
                return null;
            }
            if (!std.mem.eql(u8, envelope_type, "stream_item")) {
                return error.UnexpectedStreamEnvelope;
            }
            return message;
        }
    }

    fn control(
        self: *RawStream,
        operation: Operation,
        params: raw.wire.Value,
    ) !OwnedResult {
        if (operation.class() != .connection_control) {
            return error.WrongOperationClass;
        }
        self.client.mutex.lock();
        defer self.client.mutex.unlock();
        self.client.clearError();
        const request_id = try self.client.requestId();
        defer self.client.allocator.free(request_id);
        try self.client.sendRequest(request_id, operation, params, null);
        while (true) {
            var message = try self.client.readMessage();
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const envelope_type = try objectString(object, "type");
            if (std.mem.eql(u8, envelope_type, "response")) {
                const id = objectString(object, "id") catch {
                    message.deinit();
                    continue;
                };
                if (!std.mem.eql(u8, id, request_id)) {
                    message.deinit();
                    continue;
                }
                const ok = switch (object.get("ok") orelse
                    return error.MissingResponseStatus) {
                    .bool => |item| item,
                    else => return error.InvalidResponseStatus,
                };
                if (!ok) {
                    try self.client.setError(
                        object.get("error") orelse
                            return error.InvalidResourceError,
                    );
                    return error.RemoteError;
                }
                return .{
                    .owned = message,
                    .value = object.get("result") orelse
                        return error.MissingResponseResult,
                };
            }
            if (self.envelopeForThisStream(object)) {
                try self.pending.append(self.client.allocator, message);
            } else {
                message.deinit();
            }
        }
    }

    fn cancel(self: *RawStream) !*const StreamEnd {
        if (self.stream_end) |_| return &self.stream_end.?;
        self.client.mutex.lock();
        defer self.client.mutex.unlock();
        self.client.clearError();
        const request_id = try self.client.requestId();
        defer self.client.allocator.free(request_id);
        var arena = std.heap.ArenaAllocator.init(self.client.allocator);
        defer arena.deinit();
        var params = raw.wire.Object.init(arena.allocator());
        try params.put(
            "machine",
            .{ .string = try arena.allocator().dupe(
                u8,
                self.machine_selector,
            ) },
        );
        try params.put(
            "session",
            .{ .string = try arena.allocator().dupe(
                u8,
                self.session_selector,
            ) },
        );
        try params.put(
            "stream",
            .{ .string = try arena.allocator().dupe(
                u8,
                self.stream_id.slice(),
            ) },
        );
        try self.client.sendRequest(
            request_id,
            .stream_cancel,
            .{ .object = params },
            null,
        );
        var response_seen = false;
        while (!response_seen or self.stream_end == null) {
            var message = if (self.pending.items.len > 0)
                self.pending.orderedRemove(0)
            else
                try self.client.readMessage();
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const envelope_type = try objectString(object, "type");
            if (std.mem.eql(u8, envelope_type, "response")) {
                const id = objectString(object, "id") catch {
                    message.deinit();
                    continue;
                };
                if (!std.mem.eql(u8, id, request_id)) {
                    message.deinit();
                    continue;
                }
                const ok = switch (object.get("ok") orelse
                    return error.MissingResponseStatus) {
                    .bool => |item| item,
                    else => return error.InvalidResponseStatus,
                };
                if (!ok) {
                    try self.client.setError(
                        object.get("error") orelse
                            return error.InvalidResourceError,
                    );
                    return error.RemoteError;
                }
                response_seen = true;
                message.deinit();
                continue;
            }
            if (std.mem.eql(u8, envelope_type, "stream_end") and
                self.envelopeForThisStream(object))
            {
                try self.storeEnd(message);
                continue;
            }
            // Items already queued before cancellation are discarded.
            message.deinit();
        }
        self.client.close();
        return &self.stream_end.?;
    }
};

fn TypedStream(comptime Item: type) type {
    return struct {
        const Self = @This();
        pub const OwnedItem = OwnedStreamItem(Item);

        raw_stream: RawStream,

        pub fn deinit(self: *Self) void {
            self.raw_stream.deinit();
            self.* = undefined;
        }

        pub fn next(self: *Self) !?OwnedItem {
            var message = (try self.raw_stream.nextRaw()) orelse return null;
            errdefer message.deinit();
            var decoded = std.heap.ArenaAllocator.init(
                self.raw_stream.client.allocator,
            );
            errdefer decoded.deinit();
            const object = switch (message.value) {
                .object => |value| value,
                else => return error.ExpectedObject,
            };
            const sequence = try decimalU64(
                object.get("sequence") orelse return error.MissingField,
            );
            const cursor = if (object.get("cursor")) |cursor_value|
                switch (cursor_value) {
                    .null => null,
                    else => try parseCursor(cursor_value),
                }
            else
                null;
            const raw_item = object.get("item") orelse
                return error.MissingField;
            return .{
                .owned = message,
                .decoded = decoded,
                .sequence = sequence,
                .cursor = cursor,
                .value = try domainItem(
                    Item,
                    decoded.allocator(),
                    raw_item,
                    cursor,
                ),
            };
        }

        pub fn control(
            self: *Self,
            operation: Operation,
            params: raw.wire.Value,
        ) !OwnedResult {
            return self.raw_stream.control(operation, params);
        }

        pub fn cancel(self: *Self) !*const StreamEnd {
            return self.raw_stream.cancel();
        }

        pub fn end(self: *const Self) ?StreamEnd {
            return self.raw_stream.stream_end;
        }
    };
}

pub const SessionEventStream = TypedStream(SessionEvent);
pub const TerminalAttachmentStream = TypedStream(TerminalAttachmentItem);
pub const BrowserAttachmentStream = TypedStream(BrowserAttachmentItem);
pub const SidebarViewStream = TypedStream(SidebarViewItem);
pub const ProviderNoticeStream = TypedStream(ProviderNotice);

pub const RunOptions = struct {
    command: RunCommand,
    cwd: ?[]const u8 = null,
    name: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const CreateTerminalTabOptions = struct {
    cwd: ?[]const u8 = null,
    name: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const CreateBrowserTabOptions = struct {
    url: []const u8,
    name: ?[]const u8 = null,
    width_px: ?u32 = null,
    height_px: ?u32 = null,
};

pub const CreateWorkspaceOptions = struct {
    name: ?[]const u8 = null,
    initial_content: InitialContent = .terminal,
};

pub const OptionalStringUpdate = union(enum) {
    unchanged,
    set: []const u8,
    clear,
};

pub const ClientMetadataUpdate = struct {
    name: OptionalStringUpdate = .unchanged,
    kind: OptionalStringUpdate = .unchanged,
};

fn Params(comptime Id: type) type {
    return struct {
        const Self = @This();

        backing_allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        object: raw.wire.Object,

        fn init(
            allocator: std.mem.Allocator,
            scope: []const u8,
            target: *const ScopedSelector(Id),
            extra: ?raw.wire.Value,
        ) !Self {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            errdefer allocator.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const temp = arena.allocator();
            var object = if (extra) |extra_value|
                switch (try raw.wire.cloneValue(temp, extra_value)) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                }
            else
                raw.wire.Object.init(temp);
            try target.ancestors.putInto(&object, temp);
            try object.put(
                try temp.dupe(u8, scope),
                .{
                    .string = try target.selector.formatAlloc(temp),
                },
            );
            return .{
                .backing_allocator = allocator,
                .arena = arena,
                .object = object,
            };
        }

        fn putString(
            self: *Self,
            name: []const u8,
            text: []const u8,
        ) !void {
            const allocator = self.arena.allocator();
            try self.object.put(
                try allocator.dupe(u8, name),
                .{ .string = try allocator.dupe(u8, text) },
            );
        }

        fn putNull(self: *Self, name: []const u8) !void {
            try self.object.put(
                try self.arena.allocator().dupe(u8, name),
                .null,
            );
        }

        fn putValue(
            self: *Self,
            name: []const u8,
            value: raw.wire.Value,
        ) !void {
            const allocator = self.arena.allocator();
            try self.object.put(
                try allocator.dupe(u8, name),
                try raw.wire.cloneValue(allocator, value),
            );
        }

        fn asValue(self: *const Self) raw.wire.Value {
            return .{ .object = self.object };
        }

        fn deinit(self: *Self) void {
            self.arena.deinit();
            self.backing_allocator.destroy(self.arena);
            self.* = undefined;
        }
    };
}

fn encodeRun(
    comptime Id: type,
    params: *Params(Id),
    options: RunOptions,
) !void {
    const allocator = params.arena.allocator();
    switch (options.command) {
        .exact => |exact| {
            var argv = std.json.Array.init(allocator);
            for (exact.argv) |argument| {
                try argv.append(.{
                    .string = try allocator.dupe(u8, argument),
                });
            }
            try params.object.put(
                try allocator.dupe(u8, "argv"),
                .{ .array = argv },
            );
        },
        .shell_command => |shell| try params.putString(
            "shell",
            shell.script,
        ),
        .explicit_shell => |shell| {
            var argv = std.json.Array.init(allocator);
            try argv.append(.{
                .string = try allocator.dupe(u8, shell.executable),
            });
            try argv.append(.{
                .string = try allocator.dupe(u8, "-lc"),
            });
            try argv.append(.{
                .string = try allocator.dupe(u8, shell.script),
            });
            try params.object.put(
                try allocator.dupe(u8, "argv"),
                .{ .array = argv },
            );
        },
    }
    if (options.cwd) |cwd| try params.putString("cwd", cwd);
    if (options.name) |name| try params.putString("name", name);
    if ((options.cols == null) != (options.rows == null)) {
        return error.IncompleteTerminalSize;
    }
    if (options.cols) |cols| {
        if (cols == 0 or options.rows.? == 0) {
            return error.InvalidTerminalSize;
        }
        try params.object.put(
            try allocator.dupe(u8, "cols"),
            .{ .integer = cols },
        );
        try params.object.put(
            try allocator.dupe(u8, "rows"),
            .{ .integer = options.rows.? },
        );
    }
}

fn encodeTerminalTab(
    comptime Id: type,
    params: *Params(Id),
    options: CreateTerminalTabOptions,
) !void {
    if (options.cwd) |cwd| try params.putString("cwd", cwd);
    if (options.name) |name| try params.putString("name", name);
    if ((options.cols == null) != (options.rows == null)) {
        return error.IncompleteTerminalSize;
    }
    if (options.cols) |cols| {
        if (cols == 0 or options.rows.? == 0) {
            return error.InvalidTerminalSize;
        }
        try params.putValue("cols", .{ .integer = cols });
        try params.putValue("rows", .{ .integer = options.rows.? });
    }
}

fn encodeBrowserTab(
    comptime Id: type,
    params: *Params(Id),
    options: CreateBrowserTabOptions,
) !void {
    if (options.url.len == 0) return error.InvalidBrowserUrl;
    try params.putString("url", options.url);
    if (options.name) |name| try params.putString("name", name);
    if ((options.width_px == null) != (options.height_px == null)) {
        return error.IncompleteBrowserSize;
    }
    if (options.width_px) |width_px| {
        if (width_px == 0 or options.height_px.? == 0) {
            return error.InvalidBrowserSize;
        }
        try params.putValue("width_px", .{ .integer = width_px });
        try params.putValue(
            "height_px",
            .{ .integer = options.height_px.? },
        );
    }
}

pub fn ResourceSnapshot(comptime Id: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        id: Id,
        name: ?[]const u8,
        label: ?[]const u8,
        revision: ?u64,

        pub fn deinit(self: *Self) void {
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn decodeSnapshot(
    comptime Id: type,
    fallback_id: ?Id,
    result: OwnedResult,
) !ResourceSnapshot(Id) {
    var owned_result = result;
    errdefer owned_result.deinit();
    const object = switch (owned_result.value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    const id = if (object.get("id")) |id_value|
        switch (id_value) {
            .string => |text| try Id.parse(text),
            else => return error.ExpectedString,
        }
    else
        fallback_id orelse return error.MissingField;
    const name = if (object.get("name")) |name_value|
        switch (name_value) {
            .null => null,
            .string => |text| text,
            else => return error.ExpectedString,
        }
    else
        null;
    const label = if (object.get("label")) |label_value|
        switch (label_value) {
            .null => null,
            .string => |text| text,
            else => return error.ExpectedString,
        }
    else
        null;
    const revision = if (object.get("revision")) |revision_value|
        try decimalU64(revision_value)
    else
        null;
    const snapshot = ResourceSnapshot(Id){
        .owned = owned_result.owned,
        .id = id,
        .name = name,
        .label = label,
        .revision = revision,
    };
    owned_result = undefined;
    return snapshot;
}

const HandleConfig = struct {
    get: Operation,
    close: ?Operation = null,
    rename: ?Operation = null,
    run: ?Operation = null,
    clear_name_with_null: bool = true,
};

fn Handle(
    comptime Id: type,
    comptime scope: []const u8,
    comptime config: HandleConfig,
) type {
    return struct {
        const Self = @This();

        client: *Client,
        target: ScopedSelector(Id),

        pub fn init(client: *Client, selection: anytype) Self {
            return .{
                .client = client,
                .target = .{
                    .selector = selectorValue(Id, selection),
                },
            };
        }

        pub fn initScoped(
            client: *Client,
            selection: anytype,
            ancestors: HandleRoute,
        ) Self {
            return .{
                .client = client,
                .target = .{
                    .selector = selectorValue(Id, selection),
                    .ancestors = ancestors,
                },
            };
        }

        pub fn selector(self: Self) Selector(Id) {
            return self.target.selector;
        }

        pub fn id(self: Self) ?Id {
            return switch (self.target.selector) {
                .id => |value| value,
                .current, .name => null,
            };
        }

        pub fn session(self: Self, child: anytype) Session {
            if (comptime !std.mem.eql(u8, scope, "machine")) {
                @compileError("session() is available only on Machine");
            }
            var route = self.target.ancestors;
            route.machine = self.target.selector;
            return Session.initScoped(self.client, child, route);
        }

        pub fn workspace(self: Self, child: anytype) Workspace {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                @compileError("workspace() is available only on Session");
            }
            var route = self.target.ancestors;
            route.session = self.target.selector;
            return Workspace.initScoped(self.client, child, route);
        }

        pub fn screen(self: Self, child: anytype) Screen {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
                @compileError("screen() is available only on Workspace");
            }
            var route = self.target.ancestors;
            route.workspace = self.target.selector;
            return Screen.initScoped(self.client, child, route);
        }

        pub fn pane(self: Self, child: anytype) Pane {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                @compileError("pane() is available only on Screen");
            }
            var route = self.target.ancestors;
            route.screen = self.target.selector;
            return Pane.initScoped(self.client, child, route);
        }

        pub fn tab(self: Self, child: anytype) Tab {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                @compileError("tab() is available only on Pane");
            }
            var route = self.target.ancestors;
            route.pane = self.target.selector;
            return Tab.initScoped(self.client, child, route);
        }

        pub fn terminal(self: Self, child: anytype) Terminal {
            if (comptime !std.mem.eql(u8, scope, "tab")) {
                @compileError("terminal() is available only on Tab");
            }
            var route = self.target.ancestors;
            route.tab = self.target.selector;
            return Terminal.initScoped(self.client, child, route);
        }

        pub fn browser(self: Self, child: anytype) Browser {
            if (comptime !std.mem.eql(u8, scope, "tab")) {
                @compileError("browser() is available only on Tab");
            }
            var route = self.target.ancestors;
            route.tab = self.target.selector;
            return Browser.initScoped(self.client, child, route);
        }

        pub fn refresh(self: Self) !ResourceSnapshot(Id) {
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return decodeSnapshot(
                Id,
                self.id(),
                try self.client.read(config.get, params.asValue()),
            );
        }

        pub fn read(
            self: Self,
            operation: Operation,
            extra: ?raw.wire.Value,
        ) !OwnedResult {
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                extra,
            );
            defer params.deinit();
            return self.client.read(operation, params.asValue());
        }

        pub fn mutate(
            self: Self,
            operation: Operation,
            extra: ?raw.wire.Value,
            options: MutationOptions,
        ) !MutationResult {
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                extra,
            );
            defer params.deinit();
            return self.client.mutate(operation, params.asValue(), options);
        }

        pub fn control(
            self: Self,
            operation: Operation,
            extra: ?raw.wire.Value,
        ) !OwnedResult {
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                extra,
            );
            defer params.deinit();
            return self.client.control(operation, params.asValue());
        }

        pub fn close(
            self: Self,
            options: MutationOptions,
        ) !MutationResult {
            const operation = config.close orelse
                return error.UnsupportedHandleOperation;
            return self.mutate(operation, null, options);
        }

        pub fn rename(
            self: Self,
            name: []const u8,
            options: MutationOptions,
        ) !MutationResult {
            const operation = config.rename orelse
                return error.UnsupportedHandleOperation;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            // Empty is meaningful and is always serialized.
            try params.putString("name", name);
            return self.client.mutate(operation, params.asValue(), options);
        }

        pub fn clearName(
            self: Self,
            options: MutationOptions,
        ) !MutationResult {
            const operation = config.rename orelse
                return error.UnsupportedHandleOperation;
            if (!config.clear_name_with_null) {
                return self.rename("", options);
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putNull("name");
            return self.client.mutate(operation, params.asValue(), options);
        }

        pub fn run(
            self: Self,
            run_options: RunOptions,
            mutation: MutationOptions,
        ) !MutationResult {
            const operation = config.run orelse
                return error.UnsupportedHandleOperation;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try encodeRun(Id, &params, run_options);
            return self.client.mutate(
                operation,
                params.asValue(),
                mutation,
            );
        }

        pub fn createTerminalTab(
            self: Self,
            create: CreateTerminalTabOptions,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try encodeTerminalTab(Id, &params, create);
            return self.client.mutate(
                .tab_create_terminal,
                params.asValue(),
                mutation,
            );
        }

        pub fn createBrowserTab(
            self: Self,
            create: CreateBrowserTabOptions,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try encodeBrowserTab(Id, &params, create);
            return self.client.mutate(
                .tab_create_browser,
                params.asValue(),
                mutation,
            );
        }

        pub fn updateMetadata(
            self: Self,
            update: ClientMetadataUpdate,
        ) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            const name_unchanged = switch (update.name) {
                .unchanged => true,
                else => false,
            };
            const kind_unchanged = switch (update.kind) {
                .unchanged => true,
                else => false,
            };
            if (name_unchanged and kind_unchanged) {
                return error.EmptyMetadataUpdate;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            switch (update.name) {
                .unchanged => {},
                .set => |name| try params.putString("name", name),
                .clear => try params.putNull("name"),
            }
            switch (update.kind) {
                .unchanged => {},
                .set => |kind| try params.putString("kind", kind),
                .clear => try params.putNull("kind"),
            }
            return self.client.control(
                .client_metadata_update,
                params.asValue(),
            );
        }

        pub fn waitFor(
            self: Self,
            pattern: []const u8,
            timeout_ms: ?u64,
        ) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (pattern.len == 0) return error.InvalidWaitPattern;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("pattern", pattern);
            if (timeout_ms) |timeout| {
                const encoded = try std.fmt.allocPrint(
                    params.arena.allocator(),
                    "{d}",
                    .{timeout},
                );
                try params.putValue(
                    "timeout_ms",
                    .{ .number_string = encoded },
                );
            }
            return self.client.read(.terminal_wait, params.asValue());
        }

        pub fn writeText(
            self: Self,
            text: []const u8,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("text", text);
            return self.client.mutate(
                .terminal_input_write,
                params.asValue(),
                mutation,
            );
        }

        pub fn scroll(
            self: Self,
            delta_rows: i32,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue(
                "delta_rows",
                .{ .integer = delta_rows },
            );
            return self.client.mutate(
                .terminal_viewport_scroll,
                params.asValue(),
                mutation,
            );
        }

        pub fn resizeTerminalViewer(
            self: Self,
            cols: u16,
            rows: u16,
        ) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (cols == 0 or rows == 0) return error.InvalidTerminalSize;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue("cols", .{ .integer = cols });
            try params.putValue("rows", .{ .integer = rows });
            return self.client.control(
                .terminal_viewer_resize,
                params.asValue(),
            );
        }

        pub fn navigate(
            self: Self,
            url: []const u8,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            if (url.len == 0) return error.InvalidBrowserUrl;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("url", url);
            return self.client.mutate(
                .browser_navigate,
                params.asValue(),
                mutation,
            );
        }

        pub fn resizeBrowserViewer(
            self: Self,
            width_px: u32,
            height_px: u32,
        ) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            if (width_px == 0 or height_px == 0) {
                return error.InvalidBrowserSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue(
                "width_px",
                .{ .integer = width_px },
            );
            try params.putValue(
                "height_px",
                .{ .integer = height_px },
            );
            return self.client.control(
                .browser_viewer_resize,
                params.asValue(),
            );
        }

        pub fn setCellPixels(
            self: Self,
            width_px: u32,
            height_px: u32,
        ) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            if (width_px == 0 or height_px == 0) {
                return error.InvalidCellPixelSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue(
                "width_px",
                .{ .integer = width_px },
            );
            try params.putValue(
                "height_px",
                .{ .integer = height_px },
            );
            return self.client.control(
                .client_cell_pixels_set,
                params.asValue(),
            );
        }

        pub fn detachClient(self: Self) !OwnedResult {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            return self.control(.client_detach, null);
        }

        pub fn createWorkspace(
            self: Self,
            create: CreateWorkspaceOptions,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (create.name) |name| try params.putString("name", name);
            try params.putString(
                "initial_content",
                create.initial_content.wireName(),
            );
            return self.client.mutate(
                .workspace_create,
                params.asValue(),
                mutation,
            );
        }

        pub fn events(self: Self) !SessionEventStream {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return self.client.openSessionEvents(params.asValue());
        }

        pub fn attachTerminal(self: Self) !TerminalAttachmentStream {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return self.client.openTerminalAttachment(params.asValue());
        }

        pub fn attachBrowser(self: Self) !BrowserAttachmentStream {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return self.client.openBrowserAttachment(params.asValue());
        }

        pub fn attachSidebar(self: Self) !SidebarViewStream {
            if (comptime !std.mem.eql(u8, scope, "sidebar_view")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return self.client.openSidebarView(params.asValue());
        }

        pub fn providerNotices(
            self: Self,
            cursor: ?Cursor,
        ) !ProviderNoticeStream {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (cursor) |value| {
                const allocator = params.arena.allocator();
                var encoded = raw.wire.Object.init(allocator);
                try encoded.put(
                    try allocator.dupe(u8, "generation"),
                    .{ .string = try allocator.dupe(
                        u8,
                        value.generation,
                    ) },
                );
                try encoded.put(
                    try allocator.dupe(u8, "revision"),
                    .{ .string = try std.fmt.allocPrint(
                        allocator,
                        "{d}",
                        .{value.revision},
                    ) },
                );
                try params.putValue("cursor", .{ .object = encoded });
            }
            return self.client.openProviderNotices(params.asValue());
        }

        pub fn notice(
            self: Self,
            notice_id: ProviderNoticeId,
        ) !ProviderNoticeHandle {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            return ProviderNoticeHandle.initScoped(
                self.client,
                notice_id,
                self.id() orelse return error.SelectorRequiresResourceId,
            );
        }

        pub fn createMachine(
            self: Self,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            return self.mutate(.machine_create, null, mutation);
        }

        pub fn connectExternal(
            self: Self,
            specifier: SensitiveString,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("specifier", specifier.reveal());
            return self.client.mutate(
                .machine_connect_external,
                params.asValue(),
                mutation,
            );
        }

        pub fn invoke(
            self: Self,
            action: ProviderActionId,
            parameters: raw.wire.Object,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            return self.client.invokeProviderAction(
                self.id() orelse return error.SelectorRequiresResourceId,
                action,
                parameters,
                mutation,
            );
        }

        pub fn markWorkspace(
            self: Self,
            scoped_session: SessionId,
            scoped_workspace: WorkspaceId,
            managed: bool,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("session", scoped_session.slice());
            try params.putString("workspace", scoped_workspace.slice());
            try params.putValue("managed", .{ .bool = managed });
            return self.client.mutate(
                .provider_workspace_mark,
                params.asValue(),
                mutation,
            );
        }

        pub fn renameWorkspace(
            self: Self,
            scoped_session: SessionId,
            scoped_workspace: WorkspaceId,
            name: ?[]const u8,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("session", scoped_session.slice());
            try params.putString("workspace", scoped_workspace.slice());
            if (name) |value| {
                try params.putString("name", value);
            } else {
                try params.putNull("name");
            }
            return self.client.mutate(
                .provider_workspace_rename,
                params.asValue(),
                mutation,
            );
        }

        pub fn closeWorkspace(
            self: Self,
            scoped_session: SessionId,
            scoped_workspace: WorkspaceId,
            mutation: MutationOptions,
        ) !MutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("session", scoped_session.slice());
            try params.putString("workspace", scoped_workspace.slice());
            return self.client.mutate(
                .provider_workspace_close,
                params.asValue(),
                mutation,
            );
        }

        pub fn rendererGrant(self: Self) !*RendererGrant {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            var result = try self.control(
                .terminal_renderer_grant_create,
                null,
            );
            errdefer result.deinit();
            const object = switch (result.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            try ensureOnlyFields(
                object,
                &.{ "endpoint", "terminal_id", "token", "rights", "ttl_ms" },
            );
            const token = try objectString(object, "token");
            const endpoint = try objectString(object, "endpoint");
            const terminal_id = try TerminalId.parse(
                try objectString(object, "terminal_id"),
            );
            const ttl_ms_u64 = try decimalU64(
                object.get("ttl_ms") orelse return error.MissingField,
            );
            const ttl_ms = std.math.cast(u32, ttl_ms_u64) orelse
                return error.IntegerOverflow;
            const right_values = switch (object.get("rights") orelse
                return error.MissingField) {
                .array => |items| items.items,
                else => return error.ExpectedArray,
            };
            const rights = try self.client.allocator.alloc(
                []const u8,
                right_values.len,
            );
            errdefer self.client.allocator.free(rights);
            for (right_values, 0..) |right, index| {
                rights[index] = switch (right) {
                    .string => |text| text,
                    else => return error.ExpectedString,
                };
            }
            const grant = try RendererGrant.initLive(
                self.client.allocator,
                result.owned,
                .{
                    .endpoint = endpoint,
                    .terminal_id = terminal_id,
                    .token = .{ .bytes = token },
                    .rights = rights,
                    .ttl_ms = ttl_ms,
                },
                rights,
            );
            result = undefined;
            return grant;
        }
    };
}

pub const Machine = Handle(MachineId, "machine", .{
    .get = .machine_get,
    .close = .machine_delete,
    .rename = .machine_rename,
    .clear_name_with_null = false,
});
pub const Session = Handle(SessionId, "session", .{
    .get = .session_get,
    .close = .session_shutdown,
});
pub const Workspace = Handle(WorkspaceId, "workspace", .{
    .get = .workspace_get,
    .close = .workspace_close,
    .rename = .workspace_rename,
    .run = .workspace_run,
    .clear_name_with_null = false,
});
pub const Screen = Handle(ScreenId, "screen", .{
    .get = .screen_get,
    .close = .screen_close,
    .rename = .screen_rename,
});
pub const Pane = Handle(PaneId, "pane", .{
    .get = .pane_get,
    .close = .pane_close,
    .rename = .pane_rename,
    .run = .pane_run,
});
pub const Tab = Handle(TabId, "tab", .{
    .get = .tab_get,
    .close = .tab_close,
    .rename = .tab_rename,
});
pub const Terminal = Handle(TerminalId, "terminal", .{
    .get = .terminal_get,
    .close = .terminal_close,
});
pub const Browser = Handle(BrowserId, "browser", .{
    .get = .browser_get,
    .close = .browser_close,
});
pub const ConnectedClient = Handle(ConnectedClientId, "client", .{
    .get = .client_get,
});
pub const Notification = Handle(NotificationId, "notification", .{
    .get = .notification_list,
});
pub const Agent = Handle(AgentId, "agent", .{
    .get = .agent_list,
});
pub const PairingRequest = Handle(PairingRequestId, "pairing_request", .{
    .get = .pairing_request_list,
});
pub const FrontendProjection = Handle(
    FrontendProjectionId,
    "frontend_projection",
    .{ .get = .frontend_projection_get },
);
pub const SidebarView = Handle(SidebarViewId, "sidebar_view", .{
    .get = .sidebar_view_get,
});
pub const ProviderScope = Handle(ProviderScopeId, "provider_scope", .{
    .get = .provider_scope_list,
});
pub const ProviderAction = Handle(ProviderActionId, "provider_action", .{
    .get = .provider_scope_list,
});
pub const ProviderNoticeHandle = struct {
    const Self = @This();

    client: *Client,
    target: ScopedSelector(ProviderNoticeId),
    provider_scope: ?ProviderScopeId = null,

    pub fn init(client: *Client, id: ProviderNoticeId) Self {
        return .{
            .client = client,
            .target = .{ .selector = .{ .id = id } },
        };
    }

    fn initScoped(
        client: *Client,
        id: ProviderNoticeId,
        provider_scope: ProviderScopeId,
    ) Self {
        return .{
            .client = client,
            .target = .{ .selector = .{ .id = id } },
            .provider_scope = provider_scope,
        };
    }

    pub fn acknowledge(self: Self, sequence: u64) !OwnedResult {
        var params = try Params(ProviderNoticeId).init(
            self.client.allocator,
            "provider_notice",
            &self.target,
            null,
        );
        defer params.deinit();
        if (self.provider_scope) |provider_scope| {
            try params.putString(
                "provider_scope",
                provider_scope.slice(),
            );
        }
        const encoded_sequence = try std.fmt.allocPrint(
            params.arena.allocator(),
            "{d}",
            .{sequence},
        );
        try params.putString("sequence", encoded_sequence);
        return self.client.control(
            .provider_notice_acknowledge,
            params.asValue(),
        );
    }
};

const FakeMode = enum {
    success,
    remote_error,
};

const FakeShared = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    read_cursor: usize = 0,
    processed: usize = 0,
    mode: FakeMode,
    closed: bool = false,

    fn deinit(self: *FakeShared) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendInput(self: *FakeShared, value: []const u8) !void {
        try self.input.appendSlice(self.allocator, value);
        try self.input.append(self.allocator, '\n');
    }

    fn processRequests(self: *FakeShared) !void {
        while (std.mem.indexOfScalar(
            u8,
            self.output.items[self.processed..],
            '\n',
        )) |relative_newline| {
            const newline = self.processed + relative_newline;
            const line = self.output.items[self.processed..newline];
            self.processed = newline + 1;
            if (line.len == 0) continue;
            var request = try raw.wire.parse(
                self.allocator,
                line,
                .{},
            );
            defer request.deinit();
            const object = switch (request.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const id = try objectString(object, "id");
            const operation = try objectString(object, "operation");
            if (self.mode == .remote_error) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":false," ++ "\"error\":{{\"code\":\"mutation.indeterminate\"," ++ "\"message\":\"external effect may have committed\"," ++ "\"details\":{{\"idempotency_key\":" ++ "\"indeterminate-test-key\",\"operation\":" ++ "\"workspace.rename\",\"recovery\":" ++ "\"inspect_state_then_retry_with_new_key\"}}," ++ "\"retryable\":false}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            if (std.mem.eql(
                u8,
                operation,
                "terminal.renderer_grant.create",
            )) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{\"endpoint\":\"/tmp/renderer.sock\"," ++ "\"terminal_id\":" ++ "\"term_0123456789abcdef0123456789abcdef\"," ++ "\"token\":\"renderer-secret\"," ++ "\"rights\":[\"read\",\"input\"]," ++ "\"ttl_ms\":5000}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            if (std.mem.eql(u8, operation, "session.events")) {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                const stream_id = try objectString(params, "stream_id");
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                const item = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"stream_item\",\"stream_id\":\"{s}\"," ++ "\"sequence\":\"1\",\"cursor\":{{\"generation\":" ++ "\"g\",\"revision\":\"3\"}},\"item\":{{\"kind\":" ++ "\"future.event\",\"data\":{{\"x\":1}}," ++ "\"future\":true}}}}",
                    .{stream_id},
                );
                defer self.allocator.free(item);
                try self.appendInput(item);
                continue;
            }
            if (std.mem.eql(u8, operation, "stream.cancel")) {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                const stream_id = try objectString(params, "stream");
                const end = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"stream_end\",\"stream_id\":\"{s}\"," ++ "\"reason\":\"canceled\",\"cursor\":" ++ "{{\"generation\":\"g\",\"revision\":\"3\"}}}}",
                    .{stream_id},
                );
                defer self.allocator.free(end);
                try self.appendInput(end);
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            const response = try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{\"value\":{{\"kind\":\"terminal\"," ++ "\"workspace_id\":\"ws_0123456789abcdef0123456789abcdef\"," ++ "\"screen_id\":\"screen_0123456789abcdef0123456789abcdef\"," ++ "\"pane_id\":\"pane_0123456789abcdef0123456789abcdef\"," ++ "\"tab_id\":\"tab_0123456789abcdef0123456789abcdef\"," ++ "\"terminal_id\":\"term_0123456789abcdef0123456789abcdef\"}}," ++ "\"generation\":\"g\",\"revision\":\"7\"," ++ "\"replayed\":false}}}}",
                .{id},
            );
            defer self.allocator.free(response);
            try self.appendInput(response);
        }
    }
};

const FakeConnection = struct {
    allocator: std.mem.Allocator,
    shared: *FakeShared,

    fn create(
        allocator: std.mem.Allocator,
        shared: *FakeShared,
    ) !*FakeConnection {
        const state = try allocator.create(FakeConnection);
        state.* = .{ .allocator = allocator, .shared = shared };
        return state;
    }

    pub fn read(
        self: *FakeConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = timeout_ms;
        if (self.shared.read_cursor == self.shared.input.items.len) {
            return error.ConnectionClosed;
        }
        const count = @min(
            buffer.len,
            self.shared.input.items.len - self.shared.read_cursor,
        );
        @memcpy(
            buffer[0..count],
            self.shared.input.items[self.shared.read_cursor .. self.shared.read_cursor + count],
        );
        self.shared.read_cursor += count;
        return count;
    }

    pub fn writeAll(
        self: *FakeConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = timeout_ms;
        try self.shared.output.appendSlice(self.shared.allocator, bytes);
        try self.shared.processRequests();
    }

    pub fn close(self: *FakeConnection) void {
        self.shared.closed = true;
    }

    pub fn deinit(self: *FakeConnection) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn fakeConnection(
    allocator: std.mem.Allocator,
    shared: *FakeShared,
) !raw.transport.Connection {
    return raw.transport.Connection.from(
        try FakeConnection.create(allocator, shared),
    );
}

const StreamFactoryState = struct {
    shared: *FakeShared,

    fn open(
        context: *anyopaque,
        allocator: std.mem.Allocator,
    ) !raw.transport.Connection {
        const self: *StreamFactoryState = @ptrCast(@alignCast(context));
        return fakeConnection(allocator, self.shared);
    }
};

test "opaque IDs and selectors preserve flat scope syntax" {
    const id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    try std.testing.expectError(
        error.InvalidResourceId,
        WorkspaceId.parse("42"),
    );
    var selector = Selector(WorkspaceId){ .name = "current" };
    const encoded = try selector.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("name:current", encoded);
    try std.testing.expectEqualStrings(
        "ws_0123456789abcdef0123456789abcdef",
        id.slice(),
    );
}

test "operation inventory includes capability corrections" {
    try std.testing.expectEqualStrings(
        "terminal.renderer_grant.create",
        Operation.terminal_renderer_grant_create.wireName(),
    );
    try std.testing.expectEqual(
        OperationClass.connection_control,
        Operation.client_detach.class(),
    );
    try std.testing.expectEqual(
        OperationClass.connection_control,
        Operation.client_cell_pixels_set.class(),
    );
    try std.testing.expectEqual(
        OperationClass.connection_control,
        Operation.client_metadata_update.class(),
    );
    try std.testing.expectEqual(
        OperationClass.stream_open,
        Operation.provider_notice_events.class(),
    );
    try std.testing.expectEqual(
        OperationClass.connection_control,
        Operation.provider_notice_acknowledge.class(),
    );
}

test "client metadata preserves omitted set-empty and clear states" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const id = try ConnectedClientId.parse(
        "client_0123456789abcdef0123456789abcdef",
    );
    var result = try client.connectedClient(id).updateMetadata(.{
        .name = .{ .set = "" },
        .kind = .clear,
    });
    defer result.deinit();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"name\":\"\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"kind\":null",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "idempotency_key") ==
            null,
    );
}

test "provider notices acknowledge only after an explicit consumer call" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const scope = try ProviderScopeId.parse(
        "provider_scope_0123456789abcdef0123456789abcdef",
    );
    const notice_id = try ProviderNoticeId.parse(
        "provider_notice_0123456789abcdef0123456789abcdef",
    );
    const notice = try client.providerScope(scope).notice(notice_id);
    var result = try notice.acknowledge(42);
    defer result.deinit();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"operation\":\"provider_notice.acknowledge\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"machine\":\"current\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "\"session\"") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"provider_scope\":" ++ "\"provider_scope_0123456789abcdef0123456789abcdef\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"provider_notice\":" ++ "\"provider_notice_0123456789abcdef0123456789abcdef\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"sequence\":\"42\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "idempotency_key") ==
            null,
    );
}

test "mutation keys use independent cryptographic 128-bit values" {
    const first = MutationOptions.random();
    const second = MutationOptions.random();
    try std.testing.expectEqual(@as(usize, 36), first.key().len);
    try std.testing.expectEqual(@as(usize, 36), second.key().len);
    try std.testing.expect(!std.mem.eql(u8, first.key(), second.key()));
}

test "workspace run encodes exact argv and one injected idempotency key" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    const command = try RunCommand.argv(&.{
        "printf",
        "%s",
        "hello world",
        "$HOME",
    });
    var result = try client.workspace(id).run(
        .{ .command = command },
        (try MutationOptions.withKey("stable-test-key")).expecting(42),
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 7), result.revision);
    try std.testing.expectEqualStrings("g", result.generation);
    try std.testing.expect(!result.replayed);
    try std.testing.expect(
        std.meta.fieldIndex(MutationResult, "receipt") == null,
    );
    const created_path = (try result.createdPath()).?;
    switch (created_path) {
        .terminal => |path| try std.testing.expectEqualStrings(
            "term_0123456789abcdef0123456789abcdef",
            path.terminal_id.slice(),
        ),
        else => return error.ExpectedTerminalPath,
    }
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, shared.output.items, "idempotency_key"),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "\"argv\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "$HOME") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "\"shell\"") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"machine\":\"current\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"session\":\"current\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"expected_revision\":\"42\"",
        ) != null,
    );
}

test "remote shell remains a distinct server-expanded field" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const id = try PaneId.parse(
        "pane_0123456789abcdef0123456789abcdef",
    );
    var result = try client.pane(id).run(
        .{ .command = try RunCommand.shell("echo $REMOTE_HOME") },
        try MutationOptions.withKey("shell-test-key"),
    );
    defer result.deinit();
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "\"shell\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, shared.output.items, "\"argv\"") == null,
    );
}

test "selector handle construction is offline and nested routes are exact" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();

    const tab = client
        .machine(.{ .name = "builder" })
        .session(.current)
        .workspace(.{ .name = "sdk" })
        .screen(.{ .name = "tests" })
        .pane(.current)
        .tab(.{ .name = "output" });
    const terminal = tab.terminal(.{ .name = "shell" });
    const browser = tab.browser(.{ .name = "preview" });
    try std.testing.expectEqual(@as(usize, 0), shared.output.items.len);

    var written = try terminal.writeText(
        "hello",
        try MutationOptions.withKey("route-terminal-key"),
    );
    written.deinit();
    var navigated = try browser.navigate(
        "https://cmux.dev/sdk",
        try MutationOptions.withKey("route-browser-key"),
    );
    navigated.deinit();

    var requests = std.mem.splitScalar(u8, shared.output.items, '\n');
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"cmux.protocol/1\",\"type\":\"request\"," ++
            "\"id\":\"zig-request-1\",\"operation\":" ++
            "\"terminal.input.write\",\"params\":{" ++
            "\"machine\":\"name:builder\",\"session\":\"current\"," ++
            "\"workspace\":\"name:sdk\",\"screen\":\"name:tests\"," ++
            "\"pane\":\"current\",\"tab\":\"name:output\"," ++
            "\"terminal\":\"name:shell\",\"text\":\"hello\"}," ++
            "\"idempotency_key\":\"route-terminal-key\"}",
        requests.next().?,
    );
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"cmux.protocol/1\",\"type\":\"request\"," ++
            "\"id\":\"zig-request-2\",\"operation\":" ++
            "\"browser.navigate\",\"params\":{" ++
            "\"machine\":\"name:builder\",\"session\":\"current\"," ++
            "\"workspace\":\"name:sdk\",\"screen\":\"name:tests\"," ++
            "\"pane\":\"current\",\"tab\":\"name:output\"," ++
            "\"browser\":\"name:preview\"," ++
            "\"url\":\"https://cmux.dev/sdk\"}," ++
            "\"idempotency_key\":\"route-browser-key\"}",
        requests.next().?,
    );
}

test "client session name selector keeps current machine route" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();

    const named = client.session(.{ .name = "release" });
    try std.testing.expectEqual(@as(usize, 0), shared.output.items.len);
    var created = try named.createWorkspace(
        .{ .name = "sdk-tests", .initial_content = .empty },
        try MutationOptions.withKey("session-selector-key"),
    );
    created.deinit();
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"cmux.protocol/1\",\"type\":\"request\"," ++
            "\"id\":\"zig-request-1\",\"operation\":" ++
            "\"workspace.create\",\"params\":{" ++
            "\"machine\":\"current\",\"session\":\"name:release\"," ++
            "\"name\":\"sdk-tests\",\"initial_content\":\"empty\"}," ++
            "\"idempotency_key\":\"session-selector-key\"}\n",
        shared.output.items,
    );
}

test "indeterminate mutations retain fields and never retry" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .remote_error,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const params = raw.wire.Value{
        .object = raw.wire.Object.init(arena.allocator()),
    };
    try std.testing.expectError(
        error.RemoteError,
        client.mutate(
            .workspace_rename,
            params,
            try MutationOptions.withKey("indeterminate-test-key"),
        ),
    );
    const failure = client.lastResourceError().?;
    try std.testing.expectEqualStrings(
        "mutation.indeterminate",
        failure.code,
    );
    try std.testing.expectEqualStrings(
        "external effect may have committed",
        failure.message,
    );
    const details = failure.details.?.object;
    try std.testing.expectEqual(@as(usize, 3), details.count());
    try std.testing.expectEqualStrings(
        "indeterminate-test-key",
        details.get("idempotency_key").?.string,
    );
    try std.testing.expectEqualStrings(
        "workspace.rename",
        details.get("operation").?.string,
    );
    try std.testing.expectEqualStrings(
        "inspect_state_then_retry_with_new_key",
        details.get("recovery").?.string,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, shared.output.items, "idempotency_key"),
    );
}

test "session events decode strict snapshot delta and unknown changes" {
    const workspace_id = "ws_0123456789abcdef0123456789abcdef";
    const input =
        "{\"kind\":\"delta\",\"cursor\":{" ++
        "\"generation\":\"g\",\"revision\":\"3\"}," ++
        "\"previous_revision\":\"2\",\"revision\":\"3\",\"changes\":[" ++
        "{\"kind\":\"upsert\",\"sequence\":0,\"resource\":\"workspace\"," ++
        "\"id\":\"" ++ workspace_id ++ "\",\"value\":{" ++
        "\"id\":\"" ++ workspace_id ++ "\",\"name\":\"sdk\"}}," ++
        "{\"kind\":\"delete\",\"sequence\":1,\"resource\":\"workspace\"," ++
        "\"id\":\"" ++ workspace_id ++ "\"}," ++
        "{\"kind\":\"future.change\",\"sequence\":2,\"future\":true}" ++
        "]}";
    var parsed = try raw.wire.parse(std.testing.allocator, input, .{});
    defer parsed.deinit();
    var decoded = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded.deinit();
    const event = try decodeSessionEvent(
        decoded.allocator(),
        parsed.value,
        .{ .generation = "g", .revision = 3 },
    );
    switch (event) {
        .delta => |delta| {
            try std.testing.expectEqual(@as(u64, 2), delta.previous_revision);
            try std.testing.expectEqual(@as(u64, 3), delta.revision);
            try std.testing.expectEqual(@as(usize, 3), delta.changes.len);
            switch (delta.changes[0]) {
                .upsert => |upsert| {
                    try std.testing.expectEqual(
                        ResourceKind.workspace,
                        upsert.resource,
                    );
                    try std.testing.expectEqualStrings(
                        workspace_id,
                        upsert.id.slice(),
                    );
                },
                else => return error.ExpectedResourceUpsert,
            }
            switch (delta.changes[1]) {
                .delete => |deleted| try std.testing.expectEqual(
                    @as(u32, 1),
                    deleted.sequence,
                ),
                else => return error.ExpectedResourceDelete,
            }
            switch (delta.changes[2]) {
                .unknown => |unknown| {
                    try std.testing.expectEqualStrings(
                        "future.change",
                        unknown.discriminator,
                    );
                    try std.testing.expect(
                        unknown.raw_object.object.get("future").?.bool,
                    );
                },
                else => return error.ExpectedUnknownResourceChange,
            }
        },
        else => return error.ExpectedSessionDelta,
    }

    const snapshot_input =
        "{\"kind\":\"snapshot\",\"cursor\":{" ++
        "\"generation\":\"g\",\"revision\":\"3\"}," ++
        "\"reset_reason\":\"initial\",\"snapshot\":{}}";
    var parsed_snapshot = try raw.wire.parse(
        std.testing.allocator,
        snapshot_input,
        .{},
    );
    defer parsed_snapshot.deinit();
    const snapshot = try decodeSessionEvent(
        decoded.allocator(),
        parsed_snapshot.value,
        .{ .generation = "g", .revision = 3 },
    );
    switch (snapshot) {
        .snapshot => |item| try std.testing.expectEqual(
            ResetReason.initial,
            item.reset_reason.?,
        ),
        else => return error.ExpectedSessionSnapshot,
    }
}

test "recognized session and change variants reject malformed payloads" {
    const wrong_id =
        "{\"kind\":\"delta\",\"cursor\":{" ++
        "\"generation\":\"g\",\"revision\":\"3\"}," ++
        "\"previous_revision\":\"2\",\"revision\":\"3\",\"changes\":[" ++
        "{\"kind\":\"upsert\",\"sequence\":0,\"resource\":\"workspace\"," ++
        "\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
        "\"value\":{\"id\":" ++
        "\"term_0123456789abcdef0123456789abcdef\"}}]}";
    var parsed = try raw.wire.parse(
        std.testing.allocator,
        wrong_id,
        .{},
    );
    defer parsed.deinit();
    var decoded = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectError(
        error.InvalidResourceId,
        decodeSessionEvent(
            decoded.allocator(),
            parsed.value,
            .{ .generation = "g", .revision = 3 },
        ),
    );

    const malformed_snapshot =
        "{\"kind\":\"snapshot\",\"cursor\":{" ++
        "\"generation\":\"g\",\"revision\":\"3\"}," ++
        "\"reset_reason\":\"future\",\"snapshot\":{}}";
    var parsed_snapshot = try raw.wire.parse(
        std.testing.allocator,
        malformed_snapshot,
        .{},
    );
    defer parsed_snapshot.deinit();
    try std.testing.expectError(
        error.InvalidResetReason,
        decodeSessionEvent(
            decoded.allocator(),
            parsed_snapshot.value,
            .{ .generation = "g", .revision = 3 },
        ),
    );
}

test "typed session stream preserves unknown payload and cancel end order" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer stream_shared.deinit();
    var factory_state = StreamFactoryState{ .shared = &stream_shared };
    const connection = try fakeConnection(
        std.testing.allocator,
        &control_shared,
    );
    var client = Client.init(std.testing.allocator, connection, .{
        .stream_factory = .{
            .context = &factory_state,
            .openFn = StreamFactoryState.open,
        },
    });
    defer client.deinit();
    const session_id = try SessionId.parse(
        "session_0123456789abcdef0123456789abcdef",
    );
    var stream = try client.session(session_id).events();
    defer stream.deinit();
    var item = (try stream.next()).?;
    defer item.deinit();
    try std.testing.expectEqual(@as(u64, 1), item.sequence);
    switch (item.value) {
        .unknown => |unknown| {
            try std.testing.expectEqualStrings(
                "future.event",
                unknown.discriminator,
            );
            try std.testing.expect(
                unknown.raw_object.object.get("future") != null,
            );
        },
        else => return error.ExpectedUnknownSessionEvent,
    }
    const stream_end = try stream.cancel();
    try std.testing.expectEqual(
        StreamEndReason.canceled,
        stream_end.reason,
    );
    try std.testing.expectEqual(@as(u64, 3), stream_end.cursor.?.revision);
    var requests = std.mem.splitScalar(u8, stream_shared.output.items, '\n');
    _ = requests.next();
    const cancel_line = requests.next() orelse
        return error.MissingCancelRequest;
    var cancel_request = try raw.wire.parse(
        std.testing.allocator,
        cancel_line,
        .{},
    );
    defer cancel_request.deinit();
    const cancel_object = switch (cancel_request.value) {
        .object => |value| value,
        else => return error.ExpectedObject,
    };
    const cancel_params = switch (cancel_object.get("params") orelse
        return error.MissingField) {
        .object => |value| value,
        else => return error.ExpectedObject,
    };
    try std.testing.expectEqualStrings(
        "current",
        try objectString(cancel_params, "machine"),
    );
    try std.testing.expectEqualStrings(
        session_id.slice(),
        try objectString(cancel_params, "session"),
    );
    try std.testing.expectEqualStrings(
        stream.raw_stream.stream_id.slice(),
        try objectString(cancel_params, "stream"),
    );
    try std.testing.expect(cancel_params.get("stream_id") == null);
}

test "offline renderer grants validate and own every input slice" {
    var endpoint = [_]u8{ '/', 't', 'm', 'p', '/', 'r' };
    var token = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var right = [_]u8{ 'r', 'e', 'a', 'd' };
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const input_rights = [_][]const u8{&right};
    const grant = try RendererGrant.init(std.testing.allocator, .{
        .endpoint = &endpoint,
        .terminal_id = terminal_id,
        .token = .{ .bytes = &token },
        .rights = &input_rights,
        .ttl_ms = 5_000,
    });
    defer grant.deinit();
    endpoint[0] = 'x';
    token[0] = 'x';
    right[0] = 'x';
    try std.testing.expectEqualStrings("/tmp/r", grant.endpoint());
    try std.testing.expectEqualStrings("secret", grant.token().reveal());
    try std.testing.expectEqualStrings("read", grant.rights()[0]);
    try std.testing.expectEqualStrings(
        terminal_id.slice(),
        grant.terminalId().slice(),
    );

    try std.testing.expectError(
        error.InvalidRendererTtl,
        RendererGrant.init(std.testing.allocator, .{
            .endpoint = "/tmp/r",
            .terminal_id = terminal_id,
            .token = .{ .bytes = "secret" },
            .rights = &.{"read"},
            .ttl_ms = 0,
        }),
    );
}

test "renderer and provider credentials redact formatting" {
    const provider = ProviderCredential{ .bytes = "provider-secret" };
    const provider_text = try std.fmt.allocPrint(
        std.testing.allocator,
        "{f}",
        .{provider},
    );
    defer std.testing.allocator.free(provider_text);
    try std.testing.expectEqualStrings("[REDACTED]", provider_text);

    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const grant = try client.terminal(terminal_id).rendererGrant();
    defer grant.deinit();
    try std.testing.expectEqualStrings(
        "renderer-secret",
        grant.token().reveal(),
    );
    try std.testing.expectEqualStrings(
        "/tmp/renderer.sock",
        grant.endpoint(),
    );
    try std.testing.expectEqual(@as(u32, 5000), grant.ttlMs());
    try std.testing.expectEqual(@as(usize, 2), grant.rights().len);
    const formatted = try std.fmt.allocPrint(
        std.testing.allocator,
        "{f}",
        .{grant},
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(
        std.mem.indexOf(u8, formatted, "renderer-secret") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, formatted, "[REDACTED]") != null,
    );
}

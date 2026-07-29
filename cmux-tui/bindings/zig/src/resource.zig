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
pub const SidebarPluginId = OpaqueId("sidebar_plugin_");
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

pub const ErrorResourceScope = union(enum) {
    machine,
    session,
    workspace,
    screen,
    pane,
    tab,
    terminal,
    browser,
    client,
    split,
    stream,
    notification,
    agent,
    frontend_projection,
    pairing_request,
    sidebar_view,
    sidebar_plugin,
    provider_scope,
    provider_action,
    provider_notice,
    unknown: []const u8,

    pub fn wireName(self: ErrorResourceScope) []const u8 {
        return switch (self) {
            inline .machine,
            .session,
            .workspace,
            .screen,
            .pane,
            .tab,
            .terminal,
            .browser,
            .client,
            .split,
            .stream,
            .notification,
            .agent,
            .frontend_projection,
            .pairing_request,
            .sidebar_view,
            .sidebar_plugin,
            .provider_scope,
            .provider_action,
            .provider_notice,
            => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const ErrorResourceId = union(enum) {
    machine: MachineId,
    session: SessionId,
    workspace: WorkspaceId,
    screen: ScreenId,
    pane: PaneId,
    tab: TabId,
    terminal: TerminalId,
    browser: BrowserId,
    client: ConnectedClientId,
    split: SplitId,
    stream: StreamId,
    notification: NotificationId,
    agent: AgentId,
    frontend_projection: FrontendProjectionId,
    pairing_request: PairingRequestId,
    sidebar_view: SidebarViewId,
    sidebar_plugin: SidebarPluginId,
    provider_scope: ProviderScopeId,
    provider_action: ProviderActionId,
    provider_notice: ProviderNoticeId,
    unknown: []const u8,

    pub fn slice(self: *const ErrorResourceId) []const u8 {
        return switch (self.*) {
            inline .machine,
            .session,
            .workspace,
            .screen,
            .pane,
            .tab,
            .terminal,
            .browser,
            .client,
            .split,
            .stream,
            .notification,
            .agent,
            .frontend_projection,
            .pairing_request,
            .sidebar_view,
            .sidebar_plugin,
            .provider_scope,
            .provider_action,
            .provider_notice,
            => |*id| id.slice(),
            .unknown => |value| value,
        };
    }
};

pub const MutationRecovery = union(enum) {
    inspect_state_then_retry_with_new_key,
    unknown: []const u8,

    pub fn wireName(self: MutationRecovery) []const u8 {
        return switch (self) {
            .inspect_state_then_retry_with_new_key => "inspect_state_then_retry_with_new_key",
            .unknown => |value| value,
        };
    }
};

pub const AuthorityDeniedDetails = struct {
    operation: []const u8,
};

pub const ConfirmationRequiredDetails = struct {
    revision: u64,
    closes_panes: []const PaneId,
};

pub const CursorGapDetails = struct {
    requested: Cursor,
    current: Cursor,
    oldest_revision: u64,
};

pub const CursorInvalidDetails = struct {
    requested: Cursor,
    current: Cursor,
    reason: []const u8,
};

pub const IdempotencyConflictDetails = struct {
    idempotency_key: []const u8,
    committed_operation: []const u8,
};

pub const LocalIoDetails = struct {
    path: ?[]const u8,
    reason: []const u8,
};

pub const MutationIndeterminateDetails = struct {
    idempotency_key: []const u8,
    operation: []const u8,
    recovery: MutationRecovery,
};

pub const OperationFailedDetails = struct {
    operation: []const u8,
    reason: []const u8,
    extra: ?raw.wire.Object,
};

pub const ResourceNotFoundDetails = struct {
    scope: ErrorResourceScope,
    id: ErrorResourceId,
};

pub const RevisionConflictDetails = struct {
    expected: u64,
    actual: u64,
};

pub const SelectorAmbiguousDetails = struct {
    /// `scope` is optional for compatibility with early protocol-v1 servers.
    scope: ?ErrorResourceScope,
    /// `selector` is optional for compatibility with early protocol-v1 servers.
    selector: ?[]const u8,
    candidates: []const ErrorResourceId,
};

pub const SelectorInvalidDetails = struct {
    scope: ErrorResourceScope,
    selector: []const u8,
    reason: []const u8,
};

pub const SelectorNotFoundDetails = struct {
    scope: ErrorResourceScope,
    selector: []const u8,
};

pub const SelectorWrongParentDetails = struct {
    scope: ErrorResourceScope,
    selector: []const u8,
    parent_scope: ErrorResourceScope,
    expected_parent: []const u8,
    actual_parent: []const u8,
};

pub const TransportClosedDetails = struct {
    reason: []const u8,
};

pub const ValidationInvalidDetails = struct {
    field: ?[]const u8,
    reason: []const u8,
};

pub const UnrecognizedResourceErrorDetails = struct {
    raw: raw.wire.Value,
};

pub const MalformedResourceErrorDetails = struct {
    raw: raw.wire.Value,
};

/// Typed catalog details. Unknown error codes and malformed known details keep
/// their redacted wire value without making callers traverse JSON by default.
pub const ResourceErrorDetails = union(enum) {
    authority_denied: AuthorityDeniedDetails,
    confirmation_required: ConfirmationRequiredDetails,
    cursor_gap: CursorGapDetails,
    cursor_invalid: CursorInvalidDetails,
    idempotency_conflict: IdempotencyConflictDetails,
    local_io: LocalIoDetails,
    mutation_indeterminate: MutationIndeterminateDetails,
    operation_failed: OperationFailedDetails,
    resource_not_found: ResourceNotFoundDetails,
    revision_conflict: RevisionConflictDetails,
    selector_ambiguous: SelectorAmbiguousDetails,
    selector_invalid: SelectorInvalidDetails,
    selector_not_found: SelectorNotFoundDetails,
    selector_wrong_parent: SelectorWrongParentDetails,
    transport_closed: TransportClosedDetails,
    validation_invalid: ValidationInvalidDetails,
    unknown: UnrecognizedResourceErrorDetails,
    malformed: MalformedResourceErrorDetails,
};

pub const ResourceError = struct {
    code: []const u8,
    message: []const u8,
    details: ResourceErrorDetails,
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

pub const MutationTransportCause = enum {
    timeout,
    connection_closed,
};

/// A mutation request was fully written, but its response was lost. The
/// server may have committed the mutation.
pub const MutationTransportUncertain = struct {
    operation: Operation,
    idempotency_key: []const u8,
    cause: MutationTransportCause,
    recovery: MutationRecovery,
};

pub const OwnedMutationTransportUncertain = struct {
    arena: std.heap.ArenaAllocator,
    value: MutationTransportUncertain,

    pub fn deinit(self: *OwnedMutationTransportUncertain) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const OwnedResult = struct {
    owned: raw.wire.OwnedValue,
    value: raw.wire.Value,

    pub fn deinit(self: *OwnedResult) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

const MutationResult = struct {
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

/// Provider actions intentionally return catalog `JsonValue`.
pub const JsonMutationResult = MutationResult;

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

fn objectBool(
    object: raw.wire.Object,
    name: []const u8,
) !bool {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .bool => |item| item,
        else => error.ExpectedBool,
    };
}

fn optionalObjectString(
    object: raw.wire.Object,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn detailObject(value: raw.wire.Value) !raw.wire.Object {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn parseErrorResourceScope(value: []const u8) ErrorResourceScope {
    inline for (@typeInfo(ErrorResourceScope).@"union".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "unknown")) {
            if (std.mem.eql(u8, value, field.name)) {
                return @unionInit(
                    ErrorResourceScope,
                    field.name,
                    {},
                );
            }
        }
    }
    return .{ .unknown = value };
}

fn parseErrorScopeField(
    object: raw.wire.Object,
    required: bool,
) !?ErrorResourceScope {
    const encoded = if (object.get("scope")) |value|
        switch (value) {
            .string => |text| text,
            else => return error.ExpectedString,
        }
    else if (object.get("kind")) |legacy|
        switch (legacy) {
            .string => |text| text,
            else => return error.ExpectedString,
        }
    else if (required)
        return error.MissingField
    else
        return null;
    return parseErrorResourceScope(encoded);
}

fn parseAnyErrorResourceId(value: []const u8) !ErrorResourceId {
    if (std.mem.startsWith(u8, value, MachineId.wire_prefix)) {
        return .{ .machine = try MachineId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, SessionId.wire_prefix)) {
        return .{ .session = try SessionId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, WorkspaceId.wire_prefix)) {
        return .{ .workspace = try WorkspaceId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, ScreenId.wire_prefix)) {
        return .{ .screen = try ScreenId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, PaneId.wire_prefix)) {
        return .{ .pane = try PaneId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, TabId.wire_prefix)) {
        return .{ .tab = try TabId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, TerminalId.wire_prefix)) {
        return .{ .terminal = try TerminalId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, BrowserId.wire_prefix)) {
        return .{ .browser = try BrowserId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, ConnectedClientId.wire_prefix)) {
        return .{ .client = try ConnectedClientId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, SplitId.wire_prefix)) {
        return .{ .split = try SplitId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, StreamId.wire_prefix)) {
        return .{ .stream = try StreamId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, NotificationId.wire_prefix)) {
        return .{ .notification = try NotificationId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, AgentId.wire_prefix)) {
        return .{ .agent = try AgentId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, FrontendProjectionId.wire_prefix)) {
        return .{
            .frontend_projection = try FrontendProjectionId.parse(value),
        };
    }
    if (std.mem.startsWith(u8, value, PairingRequestId.wire_prefix)) {
        return .{ .pairing_request = try PairingRequestId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, SidebarViewId.wire_prefix)) {
        return .{ .sidebar_view = try SidebarViewId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, SidebarPluginId.wire_prefix)) {
        return .{ .sidebar_plugin = try SidebarPluginId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, ProviderScopeId.wire_prefix)) {
        return .{ .provider_scope = try ProviderScopeId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, ProviderActionId.wire_prefix)) {
        return .{ .provider_action = try ProviderActionId.parse(value) };
    }
    if (std.mem.startsWith(u8, value, ProviderNoticeId.wire_prefix)) {
        return .{ .provider_notice = try ProviderNoticeId.parse(value) };
    }
    return .{ .unknown = value };
}

fn parseScopedErrorResourceId(
    scope: ErrorResourceScope,
    value: []const u8,
) !ErrorResourceId {
    return switch (scope) {
        .machine => .{ .machine = try MachineId.parse(value) },
        .session => .{ .session = try SessionId.parse(value) },
        .workspace => .{ .workspace = try WorkspaceId.parse(value) },
        .screen => .{ .screen = try ScreenId.parse(value) },
        .pane => .{ .pane = try PaneId.parse(value) },
        .tab => .{ .tab = try TabId.parse(value) },
        .terminal => .{ .terminal = try TerminalId.parse(value) },
        .browser => .{ .browser = try BrowserId.parse(value) },
        .client => .{ .client = try ConnectedClientId.parse(value) },
        .split => .{ .split = try SplitId.parse(value) },
        .stream => .{ .stream = try StreamId.parse(value) },
        .notification => .{
            .notification = try NotificationId.parse(value),
        },
        .agent => .{ .agent = try AgentId.parse(value) },
        .frontend_projection => .{
            .frontend_projection = try FrontendProjectionId.parse(value),
        },
        .pairing_request => .{
            .pairing_request = try PairingRequestId.parse(value),
        },
        .sidebar_view => .{
            .sidebar_view = try SidebarViewId.parse(value),
        },
        .sidebar_plugin => .{
            .sidebar_plugin = try SidebarPluginId.parse(value),
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
        .unknown => try parseAnyErrorResourceId(value),
    };
}

fn parseErrorCursor(value: raw.wire.Value) !Cursor {
    const object = try detailObject(value);
    const generation = try objectString(object, "generation");
    if (generation.len == 0 or generation.len > 128) {
        return error.InvalidCursorGeneration;
    }
    return .{
        .generation = generation,
        .revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        ),
    };
}

fn parseMutationRecovery(value: []const u8) MutationRecovery {
    if (std.mem.eql(
        u8,
        value,
        "inspect_state_then_retry_with_new_key",
    )) {
        return .inspect_state_then_retry_with_new_key;
    }
    return .{ .unknown = value };
}

fn isCatalogErrorCode(code: []const u8) bool {
    return std.mem.eql(u8, code, "authority.denied") or
        std.mem.eql(u8, code, "confirmation.required") or
        std.mem.eql(u8, code, "cursor.gap") or
        std.mem.eql(u8, code, "cursor.invalid") or
        std.mem.eql(u8, code, "idempotency.conflict") or
        std.mem.eql(u8, code, "local.io") or
        std.mem.eql(u8, code, "mutation.indeterminate") or
        std.mem.eql(u8, code, "operation.failed") or
        std.mem.eql(u8, code, "resource.not_found") or
        std.mem.eql(u8, code, "revision.conflict") or
        std.mem.eql(u8, code, "selector.ambiguous") or
        std.mem.eql(u8, code, "selector.invalid") or
        std.mem.eql(u8, code, "selector.not_found") or
        std.mem.eql(u8, code, "selector.wrong_parent") or
        std.mem.eql(u8, code, "transport.closed") or
        std.mem.eql(u8, code, "validation.invalid");
}

fn parseCatalogErrorDetails(
    allocator: std.mem.Allocator,
    code: []const u8,
    value: raw.wire.Value,
) !ResourceErrorDetails {
    const object = try detailObject(value);
    if (std.mem.eql(u8, code, "authority.denied")) {
        return .{ .authority_denied = .{
            .operation = try objectString(object, "operation"),
        } };
    }
    if (std.mem.eql(u8, code, "confirmation.required")) {
        const raw_panes = switch (object.get("closes_panes") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        if (raw_panes.len == 0) return error.ExpectedNonEmptyArray;
        const panes = try allocator.alloc(PaneId, raw_panes.len);
        for (raw_panes, 0..) |item, index| {
            panes[index] = try PaneId.parse(switch (item) {
                .string => |text| text,
                else => return error.ExpectedString,
            });
        }
        return .{ .confirmation_required = .{
            .revision = try decimalU64(
                object.get("revision") orelse return error.MissingField,
            ),
            .closes_panes = panes,
        } };
    }
    if (std.mem.eql(u8, code, "cursor.gap")) {
        return .{ .cursor_gap = .{
            .requested = try parseErrorCursor(
                object.get("requested") orelse return error.MissingField,
            ),
            .current = try parseErrorCursor(
                object.get("current") orelse return error.MissingField,
            ),
            .oldest_revision = try decimalU64(
                object.get("oldest_revision") orelse
                    return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, code, "cursor.invalid")) {
        return .{ .cursor_invalid = .{
            .requested = try parseErrorCursor(
                object.get("requested") orelse return error.MissingField,
            ),
            .current = try parseErrorCursor(
                object.get("current") orelse return error.MissingField,
            ),
            .reason = try objectString(object, "reason"),
        } };
    }
    if (std.mem.eql(u8, code, "idempotency.conflict")) {
        return .{ .idempotency_conflict = .{
            .idempotency_key = try objectString(
                object,
                "idempotency_key",
            ),
            .committed_operation = try objectString(
                object,
                "committed_operation",
            ),
        } };
    }
    if (std.mem.eql(u8, code, "local.io")) {
        return .{ .local_io = .{
            .path = try optionalObjectString(object, "path"),
            .reason = try objectString(object, "reason"),
        } };
    }
    if (std.mem.eql(u8, code, "mutation.indeterminate")) {
        return .{ .mutation_indeterminate = .{
            .idempotency_key = try objectString(
                object,
                "idempotency_key",
            ),
            .operation = try objectString(object, "operation"),
            .recovery = parseMutationRecovery(
                try objectString(object, "recovery"),
            ),
        } };
    }
    if (std.mem.eql(u8, code, "operation.failed")) {
        const extra = if (object.get("extra")) |extra_value|
            switch (extra_value) {
                .null => null,
                .object => |extra_object| extra_object,
                else => return error.ExpectedObject,
            }
        else
            null;
        return .{ .operation_failed = .{
            .operation = try objectString(object, "operation"),
            .reason = try objectString(object, "reason"),
            .extra = extra,
        } };
    }
    if (std.mem.eql(u8, code, "resource.not_found")) {
        const scope = (try parseErrorScopeField(object, true)).?;
        return .{ .resource_not_found = .{
            .scope = scope,
            .id = try parseScopedErrorResourceId(
                scope,
                try objectString(object, "id"),
            ),
        } };
    }
    if (std.mem.eql(u8, code, "revision.conflict")) {
        return .{ .revision_conflict = .{
            .expected = try decimalU64(
                object.get("expected") orelse return error.MissingField,
            ),
            .actual = try decimalU64(
                object.get("actual") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, code, "selector.ambiguous")) {
        const scope = try parseErrorScopeField(object, false);
        const raw_candidates = switch (object.get("candidates") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        if (raw_candidates.len < 2) {
            return error.ExpectedAtLeastTwoCandidates;
        }
        const candidates = try allocator.alloc(
            ErrorResourceId,
            raw_candidates.len,
        );
        for (raw_candidates, 0..) |item, index| {
            const encoded = switch (item) {
                .string => |text| text,
                else => return error.ExpectedString,
            };
            candidates[index] = if (scope) |known_scope|
                try parseScopedErrorResourceId(known_scope, encoded)
            else
                try parseAnyErrorResourceId(encoded);
        }
        return .{ .selector_ambiguous = .{
            .scope = scope,
            .selector = try optionalObjectString(object, "selector"),
            .candidates = candidates,
        } };
    }
    if (std.mem.eql(u8, code, "selector.invalid")) {
        return .{ .selector_invalid = .{
            .scope = (try parseErrorScopeField(object, true)).?,
            .selector = try objectString(object, "selector"),
            .reason = try objectString(object, "reason"),
        } };
    }
    if (std.mem.eql(u8, code, "selector.not_found")) {
        return .{ .selector_not_found = .{
            .scope = (try parseErrorScopeField(object, true)).?,
            .selector = try objectString(object, "selector"),
        } };
    }
    if (std.mem.eql(u8, code, "selector.wrong_parent")) {
        return .{ .selector_wrong_parent = .{
            .scope = (try parseErrorScopeField(object, true)).?,
            .selector = try objectString(object, "selector"),
            .parent_scope = parseErrorResourceScope(
                try objectString(object, "parent_scope"),
            ),
            .expected_parent = try objectString(
                object,
                "expected_parent",
            ),
            .actual_parent = try objectString(object, "actual_parent"),
        } };
    }
    if (std.mem.eql(u8, code, "transport.closed")) {
        return .{ .transport_closed = .{
            .reason = try objectString(object, "reason"),
        } };
    }
    if (std.mem.eql(u8, code, "validation.invalid")) {
        return .{ .validation_invalid = .{
            .field = try optionalObjectString(object, "field"),
            .reason = try objectString(object, "reason"),
        } };
    }
    unreachable;
}

fn decodeResourceErrorDetails(
    allocator: std.mem.Allocator,
    code: []const u8,
    value: raw.wire.Value,
) !ResourceErrorDetails {
    if (!isCatalogErrorCode(code)) {
        return .{ .unknown = .{ .raw = value } };
    }
    return parseCatalogErrorDetails(allocator, code, value) catch |failure| {
        if (failure == error.OutOfMemory) return failure;
        return .{ .malformed = .{ .raw = value } };
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

fn mutationTransportCause(
    failure: anyerror,
) ?MutationTransportCause {
    if (failure == error.Timeout) return .timeout;
    if (failure == error.ConnectionClosed) return .connection_closed;
    return null;
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
    last_mutation_uncertain: ?OwnedMutationTransportUncertain = null,

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
        self.clearMutationTransportUncertain();
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

    /// Borrowed until the next client call, transfer, or deinitialization.
    pub fn lastMutationTransportUncertain(
        self: *const Client,
    ) ?MutationTransportUncertain {
        return if (self.last_mutation_uncertain) |failure|
            failure.value
        else
            null;
    }

    /// Transfers the uncertainty record to the caller.
    pub fn takeMutationTransportUncertain(
        self: *Client,
    ) ?OwnedMutationTransportUncertain {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.last_mutation_uncertain orelse return null;
        self.last_mutation_uncertain = null;
        return result;
    }

    fn clearError(self: *Client) void {
        if (self.last_error) |*failure| failure.deinit();
        self.last_error = null;
    }

    fn clearMutationTransportUncertain(self: *Client) void {
        if (self.last_mutation_uncertain) |*failure| failure.deinit();
        self.last_mutation_uncertain = null;
    }

    fn setMutationTransportUncertain(
        self: *Client,
        operation: Operation,
        idempotency_key: []const u8,
        cause: MutationTransportCause,
    ) !void {
        self.clearMutationTransportUncertain();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const owned_key = try arena.allocator().dupe(
            u8,
            idempotency_key,
        );
        self.last_mutation_uncertain = .{
            .arena = arena,
            .value = .{
                .operation = operation,
                .idempotency_key = owned_key,
                .cause = cause,
                .recovery = .inspect_state_then_retry_with_new_key,
            },
        };
        arena = undefined;
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
        const raw_details = try cloneRedacted(
            allocator,
            object.get("details") orelse .null,
        );
        const details = try decodeResourceErrorDetails(
            allocator,
            code,
            raw_details,
        );
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
        self.clearMutationTransportUncertain();
        const request_id = try self.requestId();
        defer self.allocator.free(request_id);
        try self.sendRequest(request_id, operation, params, mutation);
        while (true) {
            var message = self.readMessage() catch |failure| {
                if (mutation) |options| {
                    if (mutationTransportCause(failure)) |cause| {
                        try self.setMutationTransportUncertain(
                            operation,
                            options.key(),
                            cause,
                        );
                        return error.MutationTransportUncertain;
                    }
                }
                return failure;
            };
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

    fn read(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
    ) !OwnedResult {
        return self.callClass(.read, operation, params, null);
    }

    fn control(
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

    fn mutate(
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

    fn openSessionEvents(
        self: *Client,
        params: raw.wire.Value,
    ) !SessionEventStream {
        const connection = try self.streamConnection();
        return self.openSessionEventsOn(connection, params);
    }

    fn openSessionEventsOn(
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

    fn openTerminalAttachment(
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

    fn openBrowserAttachment(
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

    fn openSidebarView(
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

    fn openProviderNotices(
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

    pub fn listMachines(self: *Client) !MachineList {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        return decodeTypedList(
            MachineSnapshot,
            self.allocator,
            try self.read(
                .machine_list,
                .{ .object = raw.wire.Object.init(arena.allocator()) },
            ),
            "machines",
        );
    }

    pub fn machines(self: *Client) !MachineList {
        return self.listMachines();
    }

    fn invokeProviderAction(
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
    const raw_details = try cloneRedacted(
        owned_allocator,
        object.get("details") orelse .null,
    );
    const details = try decodeResourceErrorDetails(
        owned_allocator,
        code,
        raw_details,
    );
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

        fn control(
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

pub const TerminalHistoryOptions = struct {
    before: ?u64 = null,
    limit: ?u32 = null,
    styled: ?bool = null,
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

pub const MachineOrigin = union(enum) {
    local,
    external,
    unknown: []const u8,

    pub fn wireName(self: MachineOrigin) []const u8 {
        return switch (self) {
            .local => "local",
            .external => "external",
            .unknown => |value| value,
        };
    }
};

pub const MachineStatus = union(enum) {
    running,
    connecting,
    sleeping,
    stopped,
    unavailable,
    unknown: []const u8,

    pub fn wireName(self: MachineStatus) []const u8 {
        return switch (self) {
            .running => "running",
            .connecting => "connecting",
            .sleeping => "sleeping",
            .stopped => "stopped",
            .unavailable => "unavailable",
            .unknown => |value| value,
        };
    }
};

pub const MachineSnapshot = struct {
    id: MachineId,
    name: []const u8,
    origin: MachineOrigin,
    status: MachineStatus,
    connectable: bool,
    provider_scope_id: ?ProviderScopeId,
    deleted: bool,
    recoverable: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const SessionSnapshot = struct {
    id: SessionId,
    machine_id: MachineId,
    name: ?[]const u8,
    generation: []const u8,
    revision: u64,
    connected: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const WorkspaceSnapshot = struct {
    id: WorkspaceId,
    session_id: SessionId,
    name: []const u8,
    index: u32,
    focused: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const ClientTransport = union(enum) {
    unix,
    websocket,
    unknown: []const u8,

    pub fn wireName(self: ClientTransport) []const u8 {
        return switch (self) {
            .unix => "unix",
            .websocket => "websocket",
            .unknown => |value| value,
        };
    }
};

pub const ClientTerminalSize = struct {
    terminal_id: TerminalId,
    cols: ?u16,
    rows: ?u16,
    participating: bool,
};

pub const ClientSnapshot = struct {
    id: ConnectedClientId,
    session_id: SessionId,
    name: ?[]const u8,
    client_kind: ?[]const u8,
    transport: ClientTransport,
    connected_seconds: u64,
    attached_terminal_ids: []const TerminalId,
    sizes: []const ClientTerminalSize,
    self: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const BrowserSource = union(enum) {
    external,
    launched,
    unknown: []const u8,

    pub fn wireName(self: BrowserSource) []const u8 {
        return switch (self) {
            .external => "external",
            .launched => "launched",
            .unknown => |value| value,
        };
    }
};

pub const BrowserStatus = union(enum) {
    starting,
    live,
    failed,
    unknown: []const u8,

    pub fn wireName(self: BrowserStatus) []const u8 {
        return switch (self) {
            .starting => "starting",
            .live => "live",
            .failed => "failed",
            .unknown => |value| value,
        };
    }
};

pub const BrowserSnapshot = struct {
    id: BrowserId,
    tab_id: TabId,
    url: []const u8,
    title: []const u8,
    loading: bool,
    source: BrowserSource,
    status: BrowserStatus,
    @"error": ?[]const u8,
    frames_stalled: bool,
    size: Size,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const PixelSize = struct {
    width_px: u32,
    height_px: u32,
};

pub const BrowserViewerResizeResult = struct {
    accepted: bool,
    size: PixelSize,
};

pub const CellPixelFailure = struct {
    target: []const u8,
    reason: []const u8,
};

pub const CellPixelsResult = struct {
    width_px: u32,
    height_px: u32,
    resized_terminals: []const TerminalId,
    failures: []const CellPixelFailure,
};

pub const LayoutDirection = union(enum) {
    horizontal,
    vertical,
    unknown: []const u8,

    pub fn wireName(self: LayoutDirection) []const u8 {
        return switch (self) {
            .horizontal => "horizontal",
            .vertical => "vertical",
            .unknown => |value| value,
        };
    }
};

pub const LayoutLeaf = struct {
    pane_id: PaneId,
    tab_ids: []const TabId,
    active_tab_id: ?TabId,
};

pub const LayoutSplit = struct {
    split_id: SplitId,
    direction: LayoutDirection,
    ratio: f64,
    first: *const LayoutNode,
    second: *const LayoutNode,
};

pub const LayoutStack = struct {
    pane_ids: []const PaneId,
    expanded_pane_id: PaneId,
};

pub const LayoutColumn = struct {
    column_id: SplitId,
    width: f64,
    root: *const LayoutNode,
};

pub const LayoutViewport = struct {
    base_width: f64,
    columns: []const LayoutColumn,
};

pub const UnknownLayoutNode = struct {
    kind: []const u8,
    raw_object: raw.wire.Value,
};

pub const LayoutNode = union(enum) {
    leaf: LayoutLeaf,
    split: LayoutSplit,
    stack: LayoutStack,
    viewport: LayoutViewport,
    unknown: UnknownLayoutNode,
};

pub const LayoutDocument = struct {
    version: u32,
    screen_id: ScreenId,
    active_pane_id: PaneId,
    zoomed_pane_id: ?PaneId,
    root: *const LayoutNode,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const ScreenSnapshot = struct {
    id: ScreenId,
    workspace_id: WorkspaceId,
    name: ?[]const u8,
    index: u32,
    focused: bool,
    layout: LayoutDocument,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const PaneSnapshot = struct {
    id: PaneId,
    screen_id: ScreenId,
    name: ?[]const u8,
    focused: bool,
    zoomed: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const TabContentKind = union(enum) {
    terminal,
    browser,
    unknown: []const u8,

    pub fn wireName(self: TabContentKind) []const u8 {
        return switch (self) {
            .terminal => "terminal",
            .browser => "browser",
            .unknown => |value| value,
        };
    }
};

pub const TabContentId = union(enum) {
    terminal: TerminalId,
    browser: BrowserId,
    unknown: []const u8,

    pub fn slice(self: *const TabContentId) []const u8 {
        return switch (self.*) {
            .terminal => |*id| id.slice(),
            .browser => |*id| id.slice(),
            .unknown => |value| value,
        };
    }
};

pub const TabSnapshot = struct {
    id: TabId,
    pane_id: PaneId,
    name: ?[]const u8,
    index: u32,
    focused: bool,
    content_kind: TabContentKind,
    content_id: TabContentId,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const EmptyResult = struct {};

pub const PingResult = struct {
    alive: bool,
    cursor: Cursor,
};

pub const RenderUnderline = union(enum) {
    single,
    double,
    curly,
    dotted,
    dashed,
    unknown: []const u8,

    pub fn wireName(self: RenderUnderline) []const u8 {
        return switch (self) {
            .single => "single",
            .double => "double",
            .curly => "curly",
            .dotted => "dotted",
            .dashed => "dashed",
            .unknown => |value| value,
        };
    }
};

pub const RenderRun = struct {
    text: []const u8,
    fg: ?[]const u8,
    bg: ?[]const u8,
    attrs: u32,
    underline: ?RenderUnderline,
    width_hint: ?u16,
};

pub const RenderRow = struct {
    row: u16,
    runs: []const RenderRun,
};

pub const TerminalScreenResult = struct {
    text: []const u8,
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    cursor_visible: bool,
    /// Catalog-defined forward-compatible fields.
    extra: ?raw.wire.Object,
};

pub const TerminalStateResult = struct {
    /// Original catalog field for consumers that persist the wire form.
    state_base64: []const u8,
    /// Decoded VT replay bytes.
    state: []const u8,
    cols: u16,
    rows: u16,
};

pub const TerminalHistoryResult = struct {
    start: u64,
    next: ?u64,
    rows: []const RenderRow,
};

pub const TerminalWaitResult = struct {
    matched: bool,
    text: []const u8,
};

pub const TerminalCopyMode = union(enum) {
    screen,
    selection,
    scrollback,
    unknown: []const u8,

    pub fn wireName(self: TerminalCopyMode) []const u8 {
        return switch (self) {
            .screen => "screen",
            .selection => "selection",
            .scrollback => "scrollback",
            .unknown => |value| value,
        };
    }
};

pub const TerminalCopyResult = struct {
    mode: TerminalCopyMode,
    text: []const u8,
};

pub const ProcessInfoResult = struct {
    pid: u32,
    executable: ?[]const u8,
    argv: []const []const u8,
    cwd: ?[]const u8,
    children: []const u32,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const ViewerResizeResult = struct {
    accepted: bool,
    size: Size,
};

fn OwnedValue(comptime Value: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        value: Value,

        pub fn deinit(self: *Self) void {
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn OwnedDecodedValue(comptime Value: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        decoded: std.heap.ArenaAllocator,
        value: Value,

        pub fn deinit(self: *Self) void {
            self.decoded.deinit();
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn OwnedList(comptime Item: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        owned: raw.wire.OwnedValue,
        items: []Item,

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.items);
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn TypedMutationResult(comptime Value: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        value: Value,
        generation: []const u8,
        revision: u64,
        replayed: bool,

        pub fn deinit(self: *Self) void {
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

fn TypedDecodedMutationResult(comptime Value: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        decoded: std.heap.ArenaAllocator,
        value: Value,
        generation: []const u8,
        revision: u64,
        replayed: bool,

        pub fn deinit(self: *Self) void {
            self.decoded.deinit();
            self.owned.deinit();
            self.* = undefined;
        }
    };
}

pub const OwnedMachineSnapshot = OwnedValue(MachineSnapshot);
pub const OwnedSessionSnapshot = OwnedValue(SessionSnapshot);
pub const OwnedWorkspaceSnapshot = OwnedValue(WorkspaceSnapshot);
pub const OwnedClientSnapshot = OwnedDecodedValue(ClientSnapshot);
pub const OwnedBrowserSnapshot = OwnedValue(BrowserSnapshot);
pub const OwnedScreenSnapshot = OwnedDecodedValue(ScreenSnapshot);
pub const OwnedPaneSnapshot = OwnedValue(PaneSnapshot);
pub const OwnedTabSnapshot = OwnedValue(TabSnapshot);
pub const OwnedPingResult = OwnedValue(PingResult);
pub const OwnedEmptyResult = OwnedValue(EmptyResult);
pub const OwnedTerminalScreenResult = OwnedValue(TerminalScreenResult);
pub const OwnedTerminalStateResult =
    OwnedDecodedValue(TerminalStateResult);
pub const OwnedTerminalHistoryResult =
    OwnedDecodedValue(TerminalHistoryResult);
pub const OwnedTerminalWaitResult = OwnedValue(TerminalWaitResult);
pub const OwnedTerminalCopyResult = OwnedValue(TerminalCopyResult);
pub const OwnedProcessInfoResult = OwnedDecodedValue(ProcessInfoResult);
pub const OwnedViewerResizeResult = OwnedValue(ViewerResizeResult);
pub const OwnedBrowserViewerResizeResult =
    OwnedValue(BrowserViewerResizeResult);
pub const OwnedCellPixelsResult = OwnedDecodedValue(CellPixelsResult);
pub const MachineList = OwnedList(MachineSnapshot);
pub const SessionList = OwnedList(SessionSnapshot);
pub const WorkspaceList = OwnedList(WorkspaceSnapshot);
pub const MachineMutationResult = TypedMutationResult(MachineSnapshot);
pub const WorkspaceMutationResult = TypedMutationResult(WorkspaceSnapshot);
pub const BrowserMutationResult = TypedMutationResult(BrowserSnapshot);
pub const ScreenMutationResult =
    TypedDecodedMutationResult(ScreenSnapshot);
pub const PaneMutationResult = TypedMutationResult(PaneSnapshot);
pub const TabMutationResult = TypedMutationResult(TabSnapshot);
pub const CreatedPathMutationResult = TypedMutationResult(CreatedPath);
pub const CreatedTerminalPathMutationResult =
    TypedMutationResult(CreatedTerminalPath);
pub const CreatedBrowserPathMutationResult =
    TypedMutationResult(CreatedBrowserPath);
pub const EmptyMutationResult = TypedMutationResult(EmptyResult);

fn parseMachineOrigin(value: []const u8) MachineOrigin {
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "external")) return .external;
    return .{ .unknown = value };
}

fn parseMachineStatus(value: []const u8) MachineStatus {
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "connecting")) return .connecting;
    if (std.mem.eql(u8, value, "sleeping")) return .sleeping;
    if (std.mem.eql(u8, value, "stopped")) return .stopped;
    if (std.mem.eql(u8, value, "unavailable")) return .unavailable;
    return .{ .unknown = value };
}

fn optionalExtra(object: raw.wire.Object) !?raw.wire.Object {
    const value = object.get("extra") orelse return null;
    return switch (value) {
        .null => null,
        .object => |extra| extra,
        else => error.ExpectedObject,
    };
}

fn unsignedValue(
    comptime Int: type,
    value: raw.wire.Value,
    minimum: Int,
) !Int {
    const decoded = std.math.cast(
        Int,
        try decimalU64(value),
    ) orelse return error.IntegerOverflow;
    if (decoded < minimum) return error.IntegerOutOfRange;
    return decoded;
}

fn objectUnsigned(
    comptime Int: type,
    object: raw.wire.Object,
    name: []const u8,
    minimum: Int,
) !Int {
    return unsignedValue(
        Int,
        object.get(name) orelse return error.MissingField,
        minimum,
    );
}

fn optionalUnsigned(
    comptime Int: type,
    object: raw.wire.Object,
    name: []const u8,
    minimum: Int,
) !?Int {
    const value = object.get(name) orelse return null;
    return try unsignedValue(Int, value, minimum);
}

fn strictOptionalString(
    object: raw.wire.Object,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn requiredNullableString(
    object: raw.wire.Object,
    name: []const u8,
) !?[]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn requiredNullableId(
    comptime Id: type,
    object: raw.wire.Object,
    name: []const u8,
) !?Id {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        .string => |text| try Id.parse(text),
        else => error.ExpectedString,
    };
}

fn requiredNullableUnsigned(
    comptime Int: type,
    object: raw.wire.Object,
    name: []const u8,
    minimum: Int,
) !?Int {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        else => try unsignedValue(Int, value, minimum),
    };
}

fn strictOptionalId(
    comptime Id: type,
    object: raw.wire.Object,
    name: []const u8,
) !?Id {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| try Id.parse(text),
        else => error.ExpectedString,
    };
}

fn floatValue(value: raw.wire.Value) !f64 {
    const decoded = switch (value) {
        .float => |number| number,
        .integer => |number| @as(f64, @floatFromInt(number)),
        .number_string => |text| try std.fmt.parseFloat(f64, text),
        else => return error.ExpectedFloat,
    };
    if (!std.math.isFinite(decoded)) return error.InvalidFloat;
    return decoded;
}

fn parseClientTransport(value: []const u8) ClientTransport {
    if (std.mem.eql(u8, value, "unix")) return .unix;
    if (std.mem.eql(u8, value, "websocket")) return .websocket;
    return .{ .unknown = value };
}

fn parseBrowserSource(value: []const u8) BrowserSource {
    if (std.mem.eql(u8, value, "external")) return .external;
    if (std.mem.eql(u8, value, "launched")) return .launched;
    return .{ .unknown = value };
}

fn parseBrowserStatus(value: []const u8) BrowserStatus {
    if (std.mem.eql(u8, value, "starting")) return .starting;
    if (std.mem.eql(u8, value, "live")) return .live;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    return .{ .unknown = value };
}

fn parseLayoutDirection(value: []const u8) LayoutDirection {
    if (std.mem.eql(u8, value, "horizontal")) return .horizontal;
    if (std.mem.eql(u8, value, "vertical")) return .vertical;
    return .{ .unknown = value };
}

fn parseTabContentKind(value: []const u8) TabContentKind {
    if (std.mem.eql(u8, value, "terminal")) return .terminal;
    if (std.mem.eql(u8, value, "browser")) return .browser;
    return .{ .unknown = value };
}

fn parseRenderUnderline(value: []const u8) RenderUnderline {
    if (std.mem.eql(u8, value, "single")) return .single;
    if (std.mem.eql(u8, value, "double")) return .double;
    if (std.mem.eql(u8, value, "curly")) return .curly;
    if (std.mem.eql(u8, value, "dotted")) return .dotted;
    if (std.mem.eql(u8, value, "dashed")) return .dashed;
    return .{ .unknown = value };
}

fn parseTerminalCopyMode(value: []const u8) TerminalCopyMode {
    if (std.mem.eql(u8, value, "screen")) return .screen;
    if (std.mem.eql(u8, value, "selection")) return .selection;
    if (std.mem.eql(u8, value, "scrollback")) return .scrollback;
    return .{ .unknown = value };
}

fn decodeClientTerminalSize(
    value: raw.wire.Value,
) !ClientTerminalSize {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "terminal_id", "cols", "rows", "participating" },
    );
    const cols = try requiredNullableUnsigned(
        u16,
        object,
        "cols",
        1,
    );
    const rows = try requiredNullableUnsigned(
        u16,
        object,
        "rows",
        1,
    );
    if ((cols == null) != (rows == null)) {
        return error.IncompleteTerminalSize;
    }
    return .{
        .terminal_id = try parseRequiredId(
            TerminalId,
            object,
            "terminal_id",
        ),
        .cols = cols,
        .rows = rows,
        .participating = try objectBool(object, "participating"),
    };
}

fn decodeClientSnapshot(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ClientSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "session_id",
            "name",
            "client_kind",
            "transport",
            "connected_seconds",
            "attached_terminal_ids",
            "sizes",
            "self",
            "extra",
        },
    );
    const raw_terminal_ids = switch (object.get(
        "attached_terminal_ids",
    ) orelse return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const terminal_ids = try allocator.alloc(
        TerminalId,
        raw_terminal_ids.len,
    );
    for (raw_terminal_ids, 0..) |terminal_id, index| {
        terminal_ids[index] = switch (terminal_id) {
            .string => |text| try TerminalId.parse(text),
            else => return error.ExpectedString,
        };
    }
    const raw_sizes = switch (object.get("sizes") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const sizes = try allocator.alloc(ClientTerminalSize, raw_sizes.len);
    for (raw_sizes, 0..) |size, index| {
        sizes[index] = try decodeClientTerminalSize(size);
    }
    return .{
        .id = try parseRequiredId(ConnectedClientId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .name = try requiredNullableString(object, "name"),
        .client_kind = try requiredNullableString(
            object,
            "client_kind",
        ),
        .transport = parseClientTransport(
            try objectString(object, "transport"),
        ),
        .connected_seconds = try decimalU64(
            object.get("connected_seconds") orelse
                return error.MissingField,
        ),
        .attached_terminal_ids = terminal_ids,
        .sizes = sizes,
        .self = try objectBool(object, "self"),
        .extra = try optionalExtra(object),
    };
}

fn decodeSize(value: raw.wire.Value) !Size {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "cols", "rows" });
    return .{
        .cols = try objectUnsigned(u16, object, "cols", 1),
        .rows = try objectUnsigned(u16, object, "rows", 1),
    };
}

fn decodePixelSize(value: raw.wire.Value) !PixelSize {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "width_px", "height_px" });
    return .{
        .width_px = try objectUnsigned(
            u32,
            object,
            "width_px",
            1,
        ),
        .height_px = try objectUnsigned(
            u32,
            object,
            "height_px",
            1,
        ),
    };
}

fn decodeBrowserSnapshot(value: raw.wire.Value) !BrowserSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "tab_id",
            "url",
            "title",
            "loading",
            "source",
            "status",
            "error",
            "frames_stalled",
            "size",
            "extra",
        },
    );
    const loading = try objectBool(object, "loading");
    const status = parseBrowserStatus(
        try objectString(object, "status"),
    );
    const browser_error = try requiredNullableString(object, "error");
    switch (status) {
        .starting => if (!loading or browser_error != null)
            return error.InvalidBrowserState,
        .live => if (loading or browser_error != null)
            return error.InvalidBrowserState,
        .failed => if (loading or browser_error == null)
            return error.InvalidBrowserState,
        .unknown => {},
    }
    return .{
        .id = try parseRequiredId(BrowserId, object, "id"),
        .tab_id = try parseRequiredId(TabId, object, "tab_id"),
        .url = try objectString(object, "url"),
        .title = try objectString(object, "title"),
        .loading = loading,
        .source = parseBrowserSource(
            try objectString(object, "source"),
        ),
        .status = status,
        .@"error" = browser_error,
        .frames_stalled = try objectBool(object, "frames_stalled"),
        .size = try decodeSize(
            object.get("size") orelse return error.MissingField,
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodeBrowserViewerResizeResult(
    value: raw.wire.Value,
) !BrowserViewerResizeResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "accepted", "size" });
    return .{
        .accepted = try objectBool(object, "accepted"),
        .size = try decodePixelSize(
            object.get("size") orelse return error.MissingField,
        ),
    };
}

fn decodeCellPixelsResult(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !CellPixelsResult {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "width_px",
            "height_px",
            "resized_terminals",
            "failures",
        },
    );
    const raw_terminals = switch (object.get("resized_terminals") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const terminals = try allocator.alloc(TerminalId, raw_terminals.len);
    for (raw_terminals, 0..) |terminal, index| {
        terminals[index] = switch (terminal) {
            .string => |text| try TerminalId.parse(text),
            else => return error.ExpectedString,
        };
    }
    const failure_object = try detailObject(
        object.get("failures") orelse return error.MissingField,
    );
    const failures = try allocator.alloc(
        CellPixelFailure,
        failure_object.count(),
    );
    var failure_iterator = failure_object.iterator();
    var failure_index: usize = 0;
    while (failure_iterator.next()) |entry| : (failure_index += 1) {
        failures[failure_index] = .{
            .target = entry.key_ptr.*,
            .reason = switch (entry.value_ptr.*) {
                .string => |text| text,
                else => return error.ExpectedString,
            },
        };
    }
    return .{
        .width_px = try objectUnsigned(
            u32,
            object,
            "width_px",
            1,
        ),
        .height_px = try objectUnsigned(
            u32,
            object,
            "height_px",
            1,
        ),
        .resized_terminals = terminals,
        .failures = failures,
    };
}

fn decodeLayoutNode(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !*const LayoutNode {
    const object = try detailObject(value);
    const kind = try objectString(object, "kind");
    const node = try allocator.create(LayoutNode);
    if (std.mem.eql(u8, kind, "leaf")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "pane_id", "tab_ids", "active_tab_id" },
        );
        const raw_tabs = switch (object.get("tab_ids") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        const tab_ids = try allocator.alloc(TabId, raw_tabs.len);
        for (raw_tabs, 0..) |tab, index| {
            tab_ids[index] = switch (tab) {
                .string => |text| try TabId.parse(text),
                else => return error.ExpectedString,
            };
        }
        node.* = .{ .leaf = .{
            .pane_id = try parseRequiredId(PaneId, object, "pane_id"),
            .tab_ids = tab_ids,
            .active_tab_id = try strictOptionalId(
                TabId,
                object,
                "active_tab_id",
            ),
        } };
        return node;
    }
    if (std.mem.eql(u8, kind, "split")) {
        try ensureOnlyFields(
            object,
            &.{
                "kind",
                "split_id",
                "direction",
                "ratio",
                "first",
                "second",
            },
        );
        const ratio = try floatValue(
            object.get("ratio") orelse return error.MissingField,
        );
        if (ratio <= 0 or ratio >= 1) {
            return error.InvalidLayoutRatio;
        }
        node.* = .{ .split = .{
            .split_id = try parseRequiredId(
                SplitId,
                object,
                "split_id",
            ),
            .direction = parseLayoutDirection(
                try objectString(object, "direction"),
            ),
            .ratio = ratio,
            .first = try decodeLayoutNode(
                allocator,
                object.get("first") orelse return error.MissingField,
            ),
            .second = try decodeLayoutNode(
                allocator,
                object.get("second") orelse return error.MissingField,
            ),
        } };
        return node;
    }
    if (std.mem.eql(u8, kind, "stack")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "pane_ids", "expanded_pane_id" },
        );
        const raw_panes = switch (object.get("pane_ids") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        if (raw_panes.len == 0) return error.EmptyLayoutStack;
        const pane_ids = try allocator.alloc(PaneId, raw_panes.len);
        for (raw_panes, 0..) |pane, index| {
            pane_ids[index] = switch (pane) {
                .string => |text| try PaneId.parse(text),
                else => return error.ExpectedString,
            };
        }
        const expanded = try parseRequiredId(
            PaneId,
            object,
            "expanded_pane_id",
        );
        var contains_expanded = false;
        for (pane_ids) |pane| {
            if (std.mem.eql(
                u8,
                pane.slice(),
                expanded.slice(),
            )) {
                contains_expanded = true;
                break;
            }
        }
        if (!contains_expanded) return error.InvalidExpandedPane;
        node.* = .{ .stack = .{
            .pane_ids = pane_ids,
            .expanded_pane_id = expanded,
        } };
        return node;
    }
    if (std.mem.eql(u8, kind, "viewport")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "base_width", "columns" },
        );
        const base_width = try floatValue(
            object.get("base_width") orelse return error.MissingField,
        );
        if (base_width < 0.1 or base_width > 1) {
            return error.InvalidViewportWidth;
        }
        const raw_columns = switch (object.get("columns") orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        };
        if (raw_columns.len == 0) return error.EmptyLayoutViewport;
        const columns = try allocator.alloc(
            LayoutColumn,
            raw_columns.len,
        );
        for (raw_columns, 0..) |raw_column, index| {
            const column = try detailObject(raw_column);
            try ensureOnlyFields(
                column,
                &.{ "column_id", "width", "root" },
            );
            const width = try floatValue(
                column.get("width") orelse return error.MissingField,
            );
            if (width < 0.1 or width > 1) {
                return error.InvalidViewportWidth;
            }
            columns[index] = .{
                .column_id = try parseRequiredId(
                    SplitId,
                    column,
                    "column_id",
                ),
                .width = width,
                .root = try decodeLayoutNode(
                    allocator,
                    column.get("root") orelse
                        return error.MissingField,
                ),
            };
        }
        node.* = .{ .viewport = .{
            .base_width = base_width,
            .columns = columns,
        } };
        return node;
    }
    node.* = .{ .unknown = .{
        .kind = kind,
        .raw_object = value,
    } };
    return node;
}

fn decodeLayoutDocument(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !LayoutDocument {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "version",
            "screen_id",
            "active_pane_id",
            "zoomed_pane_id",
            "root",
            "extra",
        },
    );
    return .{
        .version = try objectUnsigned(u32, object, "version", 0),
        .screen_id = try parseRequiredId(ScreenId, object, "screen_id"),
        .active_pane_id = try parseRequiredId(
            PaneId,
            object,
            "active_pane_id",
        ),
        .zoomed_pane_id = try requiredNullableId(
            PaneId,
            object,
            "zoomed_pane_id",
        ),
        .root = try decodeLayoutNode(
            allocator,
            object.get("root") orelse return error.MissingField,
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodeScreenSnapshot(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ScreenSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "id", "workspace_id", "name", "index", "focused", "layout", "extra" },
    );
    return .{
        .id = try parseRequiredId(ScreenId, object, "id"),
        .workspace_id = try parseRequiredId(
            WorkspaceId,
            object,
            "workspace_id",
        ),
        .name = try requiredNullableString(object, "name"),
        .index = try objectUnsigned(u32, object, "index", 0),
        .focused = try objectBool(object, "focused"),
        .layout = try decodeLayoutDocument(
            allocator,
            object.get("layout") orelse return error.MissingField,
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodePaneSnapshot(value: raw.wire.Value) !PaneSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "id", "screen_id", "name", "focused", "zoomed", "extra" },
    );
    return .{
        .id = try parseRequiredId(PaneId, object, "id"),
        .screen_id = try parseRequiredId(
            ScreenId,
            object,
            "screen_id",
        ),
        .name = try requiredNullableString(object, "name"),
        .focused = try objectBool(object, "focused"),
        .zoomed = try objectBool(object, "zoomed"),
        .extra = try optionalExtra(object),
    };
}

fn decodeTabSnapshot(value: raw.wire.Value) !TabSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "pane_id",
            "name",
            "index",
            "focused",
            "content_kind",
            "content_id",
            "extra",
        },
    );
    const kind = parseTabContentKind(
        try objectString(object, "content_kind"),
    );
    const encoded_content = try objectString(object, "content_id");
    const content_id: TabContentId = switch (kind) {
        .terminal => .{
            .terminal = try TerminalId.parse(encoded_content),
        },
        .browser => .{
            .browser = try BrowserId.parse(encoded_content),
        },
        .unknown => .{ .unknown = encoded_content },
    };
    return .{
        .id = try parseRequiredId(TabId, object, "id"),
        .pane_id = try parseRequiredId(PaneId, object, "pane_id"),
        .name = try requiredNullableString(object, "name"),
        .index = try objectUnsigned(u32, object, "index", 0),
        .focused = try objectBool(object, "focused"),
        .content_kind = kind,
        .content_id = content_id,
        .extra = try optionalExtra(object),
    };
}

fn nullableColorHex(value: raw.wire.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |text| if (text.len == 7)
            text
        else
            error.InvalidColorHex,
        else => error.ExpectedString,
    };
}

fn decodeRenderRun(value: raw.wire.Value) !RenderRun {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "text", "fg", "bg", "attrs", "underline", "width_hint" },
    );
    const underline = if (object.get("underline")) |item|
        switch (item) {
            .string => |text| parseRenderUnderline(text),
            else => return error.ExpectedString,
        }
    else
        null;
    return .{
        .text = try objectString(object, "text"),
        .fg = try nullableColorHex(
            object.get("fg") orelse return error.MissingField,
        ),
        .bg = try nullableColorHex(
            object.get("bg") orelse return error.MissingField,
        ),
        .attrs = try objectUnsigned(u32, object, "attrs", 0),
        .underline = underline,
        .width_hint = try optionalUnsigned(
            u16,
            object,
            "width_hint",
            0,
        ),
    };
}

fn decodeRenderRow(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !RenderRow {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "row", "runs" });
    const raw_runs = switch (object.get("runs") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const runs = try allocator.alloc(RenderRun, raw_runs.len);
    for (raw_runs, 0..) |run, index| {
        runs[index] = try decodeRenderRun(run);
    }
    return .{
        .row = try objectUnsigned(u16, object, "row", 0),
        .runs = runs,
    };
}

fn decodeTerminalScreenResult(
    value: raw.wire.Value,
) !TerminalScreenResult {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "text",
            "cols",
            "rows",
            "cursor_row",
            "cursor_col",
            "cursor_visible",
            "extra",
        },
    );
    return .{
        .text = try objectString(object, "text"),
        .cols = try objectUnsigned(u16, object, "cols", 1),
        .rows = try objectUnsigned(u16, object, "rows", 1),
        .cursor_row = try objectUnsigned(
            u16,
            object,
            "cursor_row",
            0,
        ),
        .cursor_col = try objectUnsigned(
            u16,
            object,
            "cursor_col",
            0,
        ),
        .cursor_visible = try objectBool(object, "cursor_visible"),
        .extra = try optionalExtra(object),
    };
}

fn decodeTerminalStateResult(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !TerminalStateResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "state_base64", "cols", "rows" });
    const encoded = try objectString(object, "state_base64");
    return .{
        .state_base64 = encoded,
        .state = try raw.decodeBase64Alloc(allocator, encoded),
        .cols = try objectUnsigned(u16, object, "cols", 1),
        .rows = try objectUnsigned(u16, object, "rows", 1),
    };
}

fn decodeTerminalHistoryResult(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !TerminalHistoryResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "start", "next", "rows" });
    const raw_rows = switch (object.get("rows") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const rows = try allocator.alloc(RenderRow, raw_rows.len);
    for (raw_rows, 0..) |row, index| {
        rows[index] = try decodeRenderRow(allocator, row);
    }
    const next = if (object.get("next")) |item|
        switch (item) {
            .null => null,
            else => try decimalU64(item),
        }
    else
        null;
    return .{
        .start = try decimalU64(
            object.get("start") orelse return error.MissingField,
        ),
        .next = next,
        .rows = rows,
    };
}

fn decodeTerminalWaitResult(
    value: raw.wire.Value,
) !TerminalWaitResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "matched", "text" });
    return .{
        .matched = try objectBool(object, "matched"),
        .text = try objectString(object, "text"),
    };
}

fn decodeTerminalCopyResult(
    value: raw.wire.Value,
) !TerminalCopyResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "mode", "text" });
    return .{
        .mode = parseTerminalCopyMode(try objectString(object, "mode")),
        .text = try objectString(object, "text"),
    };
}

fn decodeProcessInfoResult(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ProcessInfoResult {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "pid", "executable", "argv", "cwd", "children" },
    );
    const raw_argv = switch (object.get("argv") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const argv = try allocator.alloc([]const u8, raw_argv.len);
    for (raw_argv, 0..) |argument, index| {
        argv[index] = switch (argument) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
    }
    const raw_children = switch (object.get("children") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const children = try allocator.alloc(u32, raw_children.len);
    for (raw_children, 0..) |child, index| {
        children[index] = try unsignedValue(u32, child, 0);
    }
    return .{
        .pid = try objectUnsigned(u32, object, "pid", 0),
        .executable = try strictOptionalString(object, "executable"),
        .argv = argv,
        .cwd = try strictOptionalString(object, "cwd"),
        .children = children,
    };
}

fn decodeViewerResizeResult(
    value: raw.wire.Value,
) !ViewerResizeResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "accepted", "size" });
    const size = try detailObject(
        object.get("size") orelse return error.MissingField,
    );
    try ensureOnlyFields(size, &.{ "cols", "rows" });
    return .{
        .accepted = try objectBool(object, "accepted"),
        .size = .{
            .cols = try objectUnsigned(u16, size, "cols", 1),
            .rows = try objectUnsigned(u16, size, "rows", 1),
        },
    };
}

fn decodeMachineSnapshot(value: raw.wire.Value) !MachineSnapshot {
    const object = try detailObject(value);
    const provider_scope_id = if (object.get("provider_scope_id")) |id|
        switch (id) {
            .null => null,
            .string => |text| try ProviderScopeId.parse(text),
            else => return error.ExpectedString,
        }
    else
        null;
    return .{
        .id = try parseRequiredId(MachineId, object, "id"),
        .name = try objectString(object, "name"),
        .origin = parseMachineOrigin(try objectString(object, "origin")),
        .status = parseMachineStatus(try objectString(object, "status")),
        .connectable = try objectBool(object, "connectable"),
        .provider_scope_id = provider_scope_id,
        .deleted = try objectBool(object, "deleted"),
        .recoverable = try objectBool(object, "recoverable"),
        .extra = try optionalExtra(object),
    };
}

fn decodeSessionSnapshot(value: raw.wire.Value) !SessionSnapshot {
    const object = try detailObject(value);
    const generation = try objectString(object, "generation");
    if (generation.len == 0 or generation.len > 128) {
        return error.InvalidMutationGeneration;
    }
    return .{
        .id = try parseRequiredId(SessionId, object, "id"),
        .machine_id = try parseRequiredId(
            MachineId,
            object,
            "machine_id",
        ),
        .name = try optionalObjectString(object, "name"),
        .generation = generation,
        .revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        ),
        .connected = try objectBool(object, "connected"),
        .extra = try optionalExtra(object),
    };
}

fn decodeWorkspaceSnapshot(value: raw.wire.Value) !WorkspaceSnapshot {
    const object = try detailObject(value);
    const index = std.math.cast(
        u32,
        try decimalU64(
            object.get("index") orelse return error.MissingField,
        ),
    ) orelse return error.IntegerOverflow;
    return .{
        .id = try parseRequiredId(WorkspaceId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .name = try objectString(object, "name"),
        .index = index,
        .focused = try objectBool(object, "focused"),
        .extra = try optionalExtra(object),
    };
}

fn decodeTypedSnapshot(
    comptime Snapshot: type,
    value: raw.wire.Value,
) !Snapshot {
    if (comptime Snapshot == MachineSnapshot) {
        return decodeMachineSnapshot(value);
    }
    if (comptime Snapshot == SessionSnapshot) {
        return decodeSessionSnapshot(value);
    }
    if (comptime Snapshot == WorkspaceSnapshot) {
        return decodeWorkspaceSnapshot(value);
    }
    if (comptime Snapshot == BrowserSnapshot) {
        return decodeBrowserSnapshot(value);
    }
    if (comptime Snapshot == PaneSnapshot) {
        return decodePaneSnapshot(value);
    }
    if (comptime Snapshot == TabSnapshot) {
        return decodeTabSnapshot(value);
    }
    @compileError("unsupported typed resource snapshot");
}

fn decodeOwnedTypedSnapshot(
    comptime Snapshot: type,
    result: OwnedResult,
) !OwnedValue(Snapshot) {
    var owned_result = result;
    errdefer owned_result.deinit();
    const decoded = try decodeTypedSnapshot(
        Snapshot,
        owned_result.value,
    );
    const snapshot = OwnedValue(Snapshot){
        .owned = owned_result.owned,
        .value = decoded,
    };
    owned_result = undefined;
    return snapshot;
}

fn listItems(
    value: raw.wire.Value,
    legacy_field: []const u8,
) ![]raw.wire.Value {
    return switch (value) {
        .array => |items| items.items,
        .object => |object| switch (object.get(legacy_field) orelse
            return error.MissingField) {
            .array => |items| items.items,
            else => error.ExpectedArray,
        },
        else => error.ExpectedArray,
    };
}

fn decodeTypedList(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    result: OwnedResult,
    legacy_field: []const u8,
) !OwnedList(Snapshot) {
    var owned_result = result;
    errdefer owned_result.deinit();
    const values = try listItems(owned_result.value, legacy_field);
    const items = try allocator.alloc(Snapshot, values.len);
    errdefer allocator.free(items);
    for (values, 0..) |value, index| {
        items[index] = try decodeTypedSnapshot(Snapshot, value);
    }
    const list = OwnedList(Snapshot){
        .allocator = allocator,
        .owned = owned_result.owned,
        .items = items,
    };
    owned_result = undefined;
    return list;
}

fn decodePingResult(result: OwnedResult) !OwnedPingResult {
    var owned_result = result;
    errdefer owned_result.deinit();
    const object = try detailObject(owned_result.value);
    const decoded = PingResult{
        .alive = try objectBool(object, "alive"),
        .cursor = try parseErrorCursor(
            object.get("cursor") orelse return error.MissingField,
        ),
    };
    const ping = OwnedPingResult{
        .owned = owned_result.owned,
        .value = decoded,
    };
    owned_result = undefined;
    return ping;
}

fn decodeEmptyResult(result: OwnedResult) !OwnedEmptyResult {
    var owned_result = result;
    errdefer owned_result.deinit();
    const object = try detailObject(owned_result.value);
    if (object.count() != 0) return error.UnexpectedField;
    const decoded = OwnedEmptyResult{
        .owned = owned_result.owned,
        .value = .{},
    };
    owned_result = undefined;
    return decoded;
}

fn decodeOwnedSimpleResult(
    comptime Result: type,
    result: OwnedResult,
) !OwnedValue(Result) {
    var owned_result = result;
    errdefer owned_result.deinit();
    const value: Result = if (comptime Result == TerminalScreenResult)
        try decodeTerminalScreenResult(owned_result.value)
    else if (comptime Result == TerminalWaitResult)
        try decodeTerminalWaitResult(owned_result.value)
    else if (comptime Result == TerminalCopyResult)
        try decodeTerminalCopyResult(owned_result.value)
    else if (comptime Result == ViewerResizeResult)
        try decodeViewerResizeResult(owned_result.value)
    else if (comptime Result == BrowserViewerResizeResult)
        try decodeBrowserViewerResizeResult(owned_result.value)
    else
        @compileError("unsupported simple result");
    const decoded = OwnedValue(Result){
        .owned = owned_result.owned,
        .value = value,
    };
    owned_result = undefined;
    return decoded;
}

fn decodeOwnedAllocatedResult(
    comptime Result: type,
    allocator: std.mem.Allocator,
    result: OwnedResult,
) !OwnedDecodedValue(Result) {
    var owned_result = result;
    errdefer owned_result.deinit();
    var decoded_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer decoded_arena.deinit();
    const value: Result = if (comptime Result == TerminalStateResult)
        try decodeTerminalStateResult(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == TerminalHistoryResult)
        try decodeTerminalHistoryResult(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == ProcessInfoResult)
        try decodeProcessInfoResult(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == ClientSnapshot)
        try decodeClientSnapshot(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == CellPixelsResult)
        try decodeCellPixelsResult(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == ScreenSnapshot)
        try decodeScreenSnapshot(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else
        @compileError("unsupported allocated result");
    const decoded = OwnedDecodedValue(Result){
        .owned = owned_result.owned,
        .decoded = decoded_arena,
        .value = value,
    };
    owned_result = undefined;
    decoded_arena = undefined;
    return decoded;
}

fn decodeTypedMutation(
    comptime Value: type,
    result: MutationResult,
) !TypedMutationResult(Value) {
    var raw_result = result;
    errdefer raw_result.deinit();
    const decoded: Value = if (comptime Value == CreatedPath)
        try parseCreatedPath(raw_result.value)
    else if (comptime Value == CreatedTerminalPath)
        switch (try parseCreatedPath(raw_result.value)) {
            .terminal => |path| path,
            else => return error.ExpectedTerminalPath,
        }
    else if (comptime Value == CreatedBrowserPath)
        switch (try parseCreatedPath(raw_result.value)) {
            .browser => |path| path,
            else => return error.ExpectedBrowserPath,
        }
    else if (comptime Value == EmptyResult) blk: {
        const object = try detailObject(raw_result.value);
        if (object.count() != 0) return error.UnexpectedField;
        break :blk .{};
    } else try decodeTypedSnapshot(Value, raw_result.value);
    const typed = TypedMutationResult(Value){
        .owned = raw_result.owned,
        .value = decoded,
        .generation = raw_result.generation,
        .revision = raw_result.revision,
        .replayed = raw_result.replayed,
    };
    raw_result = undefined;
    return typed;
}

fn decodeTypedAllocatedMutation(
    comptime Value: type,
    allocator: std.mem.Allocator,
    result: MutationResult,
) !TypedDecodedMutationResult(Value) {
    var raw_result = result;
    errdefer raw_result.deinit();
    var decoded_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer decoded_arena.deinit();
    const value: Value = if (comptime Value == ScreenSnapshot)
        try decodeScreenSnapshot(
            decoded_arena.allocator(),
            raw_result.value,
        )
    else
        @compileError("unsupported allocated mutation result");
    const typed = TypedDecodedMutationResult(Value){
        .owned = raw_result.owned,
        .decoded = decoded_arena,
        .value = value,
        .generation = raw_result.generation,
        .revision = raw_result.revision,
        .replayed = raw_result.replayed,
    };
    raw_result = undefined;
    decoded_arena = undefined;
    return typed;
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

fn RefreshResult(
    comptime Id: type,
    comptime scope: []const u8,
) type {
    if (std.mem.eql(u8, scope, "machine")) return OwnedMachineSnapshot;
    if (std.mem.eql(u8, scope, "session")) return OwnedSessionSnapshot;
    if (std.mem.eql(u8, scope, "workspace")) {
        return OwnedWorkspaceSnapshot;
    }
    return ResourceSnapshot(Id);
}

fn decodeRefreshResult(
    comptime Id: type,
    comptime scope: []const u8,
    fallback_id: ?Id,
    result: OwnedResult,
) !RefreshResult(Id, scope) {
    if (comptime std.mem.eql(u8, scope, "machine")) {
        return decodeOwnedTypedSnapshot(MachineSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "session")) {
        return decodeOwnedTypedSnapshot(SessionSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "workspace")) {
        return decodeOwnedTypedSnapshot(WorkspaceSnapshot, result);
    }
    return decodeSnapshot(Id, fallback_id, result);
}

fn RenameMutationResult(comptime scope: []const u8) type {
    if (std.mem.eql(u8, scope, "machine")) return MachineMutationResult;
    if (std.mem.eql(u8, scope, "workspace")) {
        return WorkspaceMutationResult;
    }
    if (std.mem.eql(u8, scope, "screen")) return ScreenMutationResult;
    if (std.mem.eql(u8, scope, "pane")) return PaneMutationResult;
    if (std.mem.eql(u8, scope, "tab")) return TabMutationResult;
    return EmptyMutationResult;
}

fn decodeRenameMutation(
    comptime scope: []const u8,
    allocator: std.mem.Allocator,
    result: MutationResult,
) !RenameMutationResult(scope) {
    if (comptime std.mem.eql(u8, scope, "machine")) {
        return decodeTypedMutation(MachineSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "workspace")) {
        return decodeTypedMutation(WorkspaceSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "screen")) {
        return decodeTypedAllocatedMutation(
            ScreenSnapshot,
            allocator,
            result,
        );
    }
    if (comptime std.mem.eql(u8, scope, "pane")) {
        return decodeTypedMutation(PaneSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "tab")) {
        return decodeTypedMutation(TabSnapshot, result);
    }
    var unsupported = result;
    unsupported.deinit();
    return error.UnsupportedHandleOperation;
}

fn CloseMutationResult(comptime scope: []const u8) type {
    if (std.mem.eql(u8, scope, "machine")) return MachineMutationResult;
    return EmptyMutationResult;
}

fn decodeCloseMutation(
    comptime scope: []const u8,
    result: MutationResult,
) !CloseMutationResult(scope) {
    if (comptime std.mem.eql(u8, scope, "machine")) {
        return decodeTypedMutation(MachineSnapshot, result);
    }
    return decodeTypedMutation(EmptyResult, result);
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

        pub fn refresh(self: Self) !RefreshResult(Id, scope) {
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return decodeRefreshResult(
                Id,
                scope,
                self.id(),
                try self.client.read(config.get, params.asValue()),
            );
        }

        pub fn listSessions(self: Self) !SessionList {
            if (comptime !std.mem.eql(u8, scope, "machine")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            return decodeTypedList(
                SessionSnapshot,
                self.client.allocator,
                try self.client.read(.session_list, params.asValue()),
                "sessions",
            );
        }

        pub fn listWorkspaces(self: Self) !WorkspaceList {
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
            return decodeTypedList(
                WorkspaceSnapshot,
                self.client.allocator,
                try self.client.read(.workspace_list, params.asValue()),
                "workspaces",
            );
        }

        pub fn ping(self: Self) !OwnedPingResult {
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
            return decodePingResult(
                try self.client.read(.session_ping, params.asValue()),
            );
        }

        fn read(
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

        fn mutate(
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

        fn control(
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
        ) !CloseMutationResult(scope) {
            const operation = config.close orelse
                return error.UnsupportedHandleOperation;
            return decodeCloseMutation(
                scope,
                try self.mutate(operation, null, options),
            );
        }

        pub fn rename(
            self: Self,
            name: []const u8,
            options: MutationOptions,
        ) !RenameMutationResult(scope) {
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
            return decodeRenameMutation(
                scope,
                self.client.allocator,
                try self.client.mutate(
                    operation,
                    params.asValue(),
                    options,
                ),
            );
        }

        pub fn clearName(
            self: Self,
            options: MutationOptions,
        ) !RenameMutationResult(scope) {
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
            return decodeRenameMutation(
                scope,
                self.client.allocator,
                try self.client.mutate(
                    operation,
                    params.asValue(),
                    options,
                ),
            );
        }

        pub fn run(
            self: Self,
            run_options: RunOptions,
            mutation: MutationOptions,
        ) !CreatedTerminalPathMutationResult {
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
            return decodeTypedMutation(
                CreatedTerminalPath,
                try self.client.mutate(
                    operation,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn createTerminalTab(
            self: Self,
            create: CreateTerminalTabOptions,
            mutation: MutationOptions,
        ) !CreatedTerminalPathMutationResult {
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
            return decodeTypedMutation(
                CreatedTerminalPath,
                try self.client.mutate(
                    .tab_create_terminal,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn createBrowserTab(
            self: Self,
            create: CreateBrowserTabOptions,
            mutation: MutationOptions,
        ) !CreatedBrowserPathMutationResult {
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
            return decodeTypedMutation(
                CreatedBrowserPath,
                try self.client.mutate(
                    .tab_create_browser,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn updateMetadata(
            self: Self,
            update: ClientMetadataUpdate,
        ) !OwnedClientSnapshot {
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
            return decodeOwnedAllocatedResult(
                ClientSnapshot,
                self.client.allocator,
                try self.client.control(
                    .client_metadata_update,
                    params.asValue(),
                ),
            );
        }

        pub fn readScreen(
            self: Self,
        ) !OwnedTerminalScreenResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeOwnedSimpleResult(
                TerminalScreenResult,
                try self.read(.terminal_screen_read, null),
            );
        }

        pub fn readState(
            self: Self,
        ) !OwnedTerminalStateResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeOwnedAllocatedResult(
                TerminalStateResult,
                self.client.allocator,
                try self.read(.terminal_state_read, null),
            );
        }

        pub fn readHistory(
            self: Self,
            options: TerminalHistoryOptions,
        ) !OwnedTerminalHistoryResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (options.limit) |limit| {
                if (limit == 0 or limit > 10_000) {
                    return error.InvalidHistoryLimit;
                }
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (options.before) |before| {
                const encoded = try std.fmt.allocPrint(
                    params.arena.allocator(),
                    "{d}",
                    .{before},
                );
                try params.putValue(
                    "before",
                    .{ .string = encoded },
                );
            }
            if (options.limit) |limit| {
                try params.putValue("limit", .{ .integer = limit });
            }
            if (options.styled) |styled| {
                try params.putValue("styled", .{ .bool = styled });
            }
            return decodeOwnedAllocatedResult(
                TerminalHistoryResult,
                self.client.allocator,
                try self.client.read(
                    .terminal_history_read,
                    params.asValue(),
                ),
            );
        }

        pub fn copy(
            self: Self,
            mode: ?TerminalCopyMode,
        ) !OwnedTerminalCopyResult {
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
            if (mode) |value| {
                try params.putString("mode", value.wireName());
            }
            return decodeOwnedSimpleResult(
                TerminalCopyResult,
                try self.client.read(
                    .terminal_copy,
                    params.asValue(),
                ),
            );
        }

        pub fn processInfo(
            self: Self,
        ) !OwnedProcessInfoResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeOwnedAllocatedResult(
                ProcessInfoResult,
                self.client.allocator,
                try self.read(.terminal_process_get, null),
            );
        }

        pub fn waitFor(
            self: Self,
            pattern: []const u8,
            timeout_ms: ?u64,
        ) !OwnedTerminalWaitResult {
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
                    .{ .string = encoded },
                );
            }
            return decodeOwnedSimpleResult(
                TerminalWaitResult,
                try self.client.read(.terminal_wait, params.asValue()),
            );
        }

        pub fn clearHistory(
            self: Self,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                EmptyResult,
                try self.mutate(
                    .terminal_history_clear,
                    null,
                    mutation,
                ),
            );
        }

        pub fn writeText(
            self: Self,
            text: []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_input_write,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn scroll(
            self: Self,
            delta_rows: i32,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_viewport_scroll,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn resizeTerminalViewer(
            self: Self,
            cols: u16,
            rows: u16,
        ) !OwnedViewerResizeResult {
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
            return decodeOwnedSimpleResult(
                ViewerResizeResult,
                try self.client.control(
                    .terminal_viewer_resize,
                    params.asValue(),
                ),
            );
        }

        pub fn releaseTerminalViewer(
            self: Self,
        ) !OwnedEmptyResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeEmptyResult(
                try self.control(.terminal_viewer_release, null),
            );
        }

        pub fn navigate(
            self: Self,
            url: []const u8,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
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
            return decodeTypedMutation(
                BrowserSnapshot,
                try self.client.mutate(
                    .browser_navigate,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn resizeBrowserViewer(
            self: Self,
            width_px: u32,
            height_px: u32,
        ) !OwnedBrowserViewerResizeResult {
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
            return decodeOwnedSimpleResult(
                BrowserViewerResizeResult,
                try self.client.control(
                    .browser_viewer_resize,
                    params.asValue(),
                ),
            );
        }

        pub fn setCellPixels(
            self: Self,
            width_px: u32,
            height_px: u32,
        ) !OwnedCellPixelsResult {
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
            return decodeOwnedAllocatedResult(
                CellPixelsResult,
                self.client.allocator,
                try self.client.control(
                    .client_cell_pixels_set,
                    params.asValue(),
                ),
            );
        }

        pub fn detachClient(self: Self) !OwnedEmptyResult {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeEmptyResult(
                try self.control(.client_detach, null),
            );
        }

        pub fn createWorkspace(
            self: Self,
            create: CreateWorkspaceOptions,
            mutation: MutationOptions,
        ) !CreatedPathMutationResult {
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
            return decodeTypedMutation(
                CreatedPath,
                try self.client.mutate(
                    .workspace_create,
                    params.asValue(),
                    mutation,
                ),
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
        ) !MachineMutationResult {
            if (comptime !std.mem.eql(u8, scope, "provider_scope")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                MachineSnapshot,
                try self.mutate(.machine_create, null, mutation),
            );
        }

        pub fn connectExternal(
            self: Self,
            specifier: SensitiveString,
            mutation: MutationOptions,
        ) !MachineMutationResult {
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
            return decodeTypedMutation(
                MachineSnapshot,
                try self.client.mutate(
                    .machine_connect_external,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn invoke(
            self: Self,
            action: ProviderActionId,
            parameters: raw.wire.Object,
            mutation: MutationOptions,
        ) !JsonMutationResult {
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
        ) !WorkspaceMutationResult {
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
            return decodeTypedMutation(
                WorkspaceSnapshot,
                try self.client.mutate(
                    .provider_workspace_mark,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn renameWorkspace(
            self: Self,
            scoped_session: SessionId,
            scoped_workspace: WorkspaceId,
            name: ?[]const u8,
            mutation: MutationOptions,
        ) !WorkspaceMutationResult {
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
            return decodeTypedMutation(
                WorkspaceSnapshot,
                try self.client.mutate(
                    .provider_workspace_rename,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn closeWorkspace(
            self: Self,
            scoped_session: SessionId,
            scoped_workspace: WorkspaceId,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .provider_workspace_close,
                    params.asValue(),
                    mutation,
                ),
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

    pub fn acknowledge(self: Self, sequence: u64) !OwnedEmptyResult {
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
        return decodeEmptyResult(
            try self.client.control(
                .provider_notice_acknowledge,
                params.asValue(),
            ),
        );
    }
};

const FakeMode = enum {
    success,
    remote_error,
    typed_catalog,
    dropped_mutation_timeout,
    dropped_mutation_disconnect,
};

const fake_layout_json =
    "{\"version\":1," ++
    "\"screen_id\":\"screen_55555555555555555555555555555555\"," ++
    "\"active_pane_id\":\"pane_66666666666666666666666666666666\"," ++
    "\"zoomed_pane_id\":null,\"root\":{\"kind\":\"leaf\"," ++
    "\"pane_id\":\"pane_66666666666666666666666666666666\"," ++
    "\"tab_ids\":[\"tab_77777777777777777777777777777777\"]," ++
    "\"active_tab_id\":\"tab_77777777777777777777777777777777\"}," ++
    "\"extra\":{\"layout_future\":true}}";

const fake_screen_snapshot_json =
    "{\"id\":\"screen_55555555555555555555555555555555\"," ++
    "\"workspace_id\":\"ws_33333333333333333333333333333333\"," ++
    "\"name\":\"screen-name\",\"index\":3,\"focused\":true," ++
    "\"layout\":" ++ fake_layout_json ++
    ",\"extra\":{\"screen_future\":true}}";

const fake_pane_snapshot_json =
    "{\"id\":\"pane_66666666666666666666666666666666\"," ++
    "\"screen_id\":\"screen_55555555555555555555555555555555\"," ++
    "\"name\":\"pane-name\",\"focused\":true,\"zoomed\":false," ++
    "\"extra\":{\"pane_future\":true}}";

const fake_tab_snapshot_json =
    "{\"id\":\"tab_77777777777777777777777777777777\"," ++
    "\"pane_id\":\"pane_66666666666666666666666666666666\"," ++
    "\"name\":\"tab-name\",\"index\":4,\"focused\":true," ++
    "\"content_kind\":\"terminal\"," ++
    "\"content_id\":\"term_0123456789abcdef0123456789abcdef\"," ++
    "\"extra\":{\"tab_future\":true}}";

const fake_browser_snapshot_json =
    "{\"id\":\"browser_88888888888888888888888888888888\"," ++
    "\"tab_id\":\"tab_77777777777777777777777777777777\"," ++
    "\"url\":\"https://cmux.dev/sdk\",\"title\":\"cmux\"," ++
    "\"loading\":false,\"source\":\"launched\",\"status\":\"live\"," ++
    "\"error\":null,\"frames_stalled\":false," ++
    "\"size\":{\"cols\":120,\"rows\":40}," ++
    "\"extra\":{\"browser_future\":true}}";

const fake_client_snapshot_json =
    "{\"id\":\"client_99999999999999999999999999999999\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"name\":\"sdk-client\",\"client_kind\":null,\"transport\":\"unix\"," ++
    "\"connected_seconds\":\"12\",\"attached_terminal_ids\":[" ++
    "\"term_0123456789abcdef0123456789abcdef\"],\"sizes\":[{" ++
    "\"terminal_id\":\"term_0123456789abcdef0123456789abcdef\"," ++
    "\"cols\":120,\"rows\":40,\"participating\":true}]," ++
    "\"self\":true,\"extra\":{\"client_future\":true}}";

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
            if ((self.mode == .dropped_mutation_timeout or
                self.mode == .dropped_mutation_disconnect) and
                object.get("idempotency_key") != null)
            {
                continue;
            }
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
            if (self.mode == .typed_catalog) {
                const machine =
                    "{\"id\":\"machine_11111111111111111111111111111111\"," ++
                    "\"name\":\"local\",\"origin\":\"local\"," ++
                    "\"status\":\"running\",\"connectable\":true," ++
                    "\"deleted\":false,\"recoverable\":false}";
                const session =
                    "{\"id\":\"session_22222222222222222222222222222222\"," ++
                    "\"machine_id\":" ++
                    "\"machine_11111111111111111111111111111111\"," ++
                    "\"name\":\"main\",\"generation\":\"catalog-g\"," ++
                    "\"revision\":\"9\",\"connected\":true}";
                const workspace_a =
                    "{\"id\":\"ws_33333333333333333333333333333333\"," ++
                    "\"session_id\":" ++
                    "\"session_22222222222222222222222222222222\"," ++
                    "\"name\":\"duplicate\",\"index\":1," ++
                    "\"focused\":true}";
                const workspace_b =
                    "{\"id\":\"ws_44444444444444444444444444444444\"," ++
                    "\"session_id\":" ++
                    "\"session_22222222222222222222222222222222\"," ++
                    "\"name\":\"duplicate\",\"index\":2," ++
                    "\"focused\":false}";
                const read_value: ?[]const u8 =
                    if (std.mem.eql(u8, operation, "machine.list"))
                        "[" ++ machine ++ "]"
                    else if (std.mem.eql(u8, operation, "machine.get"))
                        machine
                    else if (std.mem.eql(u8, operation, "session.list"))
                        "[" ++ session ++ "]"
                    else if (std.mem.eql(u8, operation, "session.get"))
                        session
                    else if (std.mem.eql(u8, operation, "workspace.list"))
                        "[" ++ workspace_a ++ "," ++ workspace_b ++ "]"
                    else if (std.mem.eql(u8, operation, "workspace.get"))
                        workspace_a
                    else if (std.mem.eql(u8, operation, "session.ping"))
                        "{\"alive\":true,\"cursor\":{" ++
                            "\"generation\":\"catalog-g\"," ++
                            "\"revision\":\"9\"}}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.screen.read",
                    ))
                        "{\"text\":\"prompt$ \",\"cols\":120," ++
                            "\"rows\":40,\"cursor_row\":3," ++
                            "\"cursor_col\":8,\"cursor_visible\":true," ++
                            "\"extra\":{\"future\":\"kept\"}}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.state.read",
                    ))
                        "{\"state_base64\":\"aGVsbG8=\"," ++
                            "\"cols\":120,\"rows\":40}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.history.read",
                    ))
                        "{\"start\":\"41\",\"next\":\"43\",\"rows\":[" ++
                            "{\"row\":2,\"runs\":[{\"text\":\"hello\"," ++
                            "\"fg\":\"#112233\",\"bg\":null," ++
                            "\"attrs\":5,\"underline\":\"curly\"," ++
                            "\"width_hint\":5}]}]}"
                    else if (std.mem.eql(u8, operation, "terminal.wait"))
                        "{\"matched\":true,\"text\":\"ready\"}"
                    else if (std.mem.eql(u8, operation, "terminal.copy"))
                        "{\"mode\":\"selection\",\"text\":\"copied\"}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.process.get",
                    ))
                        "{\"pid\":123,\"executable\":\"/bin/zsh\"," ++
                            "\"argv\":[\"zsh\",\"-l\"],\"cwd\":\"/tmp\"," ++
                            "\"children\":[124,125]}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.viewer.resize",
                    ))
                        "{\"accepted\":true,\"size\":{" ++
                            "\"cols\":100,\"rows\":30}}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.viewer.release",
                    ))
                        "{}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "client.metadata.update",
                    ))
                        fake_client_snapshot_json
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "browser.viewer.resize",
                    ))
                        "{\"accepted\":true,\"size\":{" ++
                            "\"width_px\":1440,\"height_px\":900}}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "client.cell_pixels.set",
                    ))
                        "{\"width_px\":9,\"height_px\":18," ++
                            "\"resized_terminals\":[" ++
                            "\"term_0123456789abcdef0123456789abcdef\"]," ++
                            "\"failures\":{\"detached\":\"not attached\"}}"
                    else
                        null;
                if (read_value) |value| {
                    const response = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                            "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                            "\"result\":{s}}}",
                        .{ id, value },
                    );
                    defer self.allocator.free(response);
                    try self.appendInput(response);
                    continue;
                }
                const mutation_value: ?[]const u8 =
                    if (std.mem.eql(u8, operation, "workspace.rename"))
                        workspace_a
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "workspace.create",
                    ))
                        "{\"kind\":\"workspace\",\"workspace_id\":" ++
                            "\"ws_33333333333333333333333333333333\"}"
                    else if (std.mem.eql(u8, operation, "workspace.close"))
                        "{}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.history.clear",
                    ))
                        "{}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "browser.navigate",
                    ))
                        fake_browser_snapshot_json
                    else if (std.mem.eql(u8, operation, "screen.rename"))
                        fake_screen_snapshot_json
                    else if (std.mem.eql(u8, operation, "pane.rename"))
                        fake_pane_snapshot_json
                    else if (std.mem.eql(u8, operation, "tab.rename"))
                        fake_tab_snapshot_json
                    else
                        null;
                if (mutation_value) |value| {
                    const response = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                            "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                            "\"result\":{{\"value\":{s}," ++
                            "\"generation\":\"catalog-g\"," ++
                            "\"revision\":\"10\"," ++
                            "\"replayed\":false}}}}",
                        .{ id, value },
                    );
                    defer self.allocator.free(response);
                    try self.appendInput(response);
                    continue;
                }
            }
            if (std.mem.eql(
                u8,
                operation,
                "client.metadata.update",
            )) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                        "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                        "\"result\":{s}}}",
                    .{ id, fake_client_snapshot_json },
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            if (std.mem.eql(u8, operation, "browser.navigate")) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                        "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                        "\"result\":{{\"value\":{s}," ++
                        "\"generation\":\"g\",\"revision\":\"7\"," ++
                        "\"replayed\":false}}}}",
                    .{ id, fake_browser_snapshot_json },
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
            if (std.mem.eql(
                u8,
                operation,
                "provider_notice.acknowledge",
            ) or std.mem.eql(u8, operation, "client.detach")) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                        "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                        "\"result\":{{}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            if (std.mem.eql(
                u8,
                operation,
                "terminal.input.write",
            ) or std.mem.eql(
                u8,
                operation,
                "terminal.viewport.scroll",
            )) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/1\",\"type\":" ++
                        "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                        "\"result\":{{\"value\":{{}}," ++
                        "\"generation\":\"g\",\"revision\":\"7\"," ++
                        "\"replayed\":false}}}}",
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
            if (self.shared.mode == .dropped_mutation_timeout) {
                return error.Timeout;
            }
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
        std.meta.fieldIndex(
            CreatedTerminalPathMutationResult,
            "receipt",
        ) == null,
    );
    try std.testing.expectEqualStrings(
        "term_0123456789abcdef0123456789abcdef",
        result.value.terminal_id.slice(),
    );
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

test "typed catalogs preserve duplicate names and own response storage" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .typed_catalog,
    };
    defer shared.deinit();

    var catalog = blk: {
        const connection = try fakeConnection(
            std.testing.allocator,
            &shared,
        );
        var client = Client.init(
            std.testing.allocator,
            connection,
            .{},
        );
        defer client.deinit();

        var machines = try client.listMachines();
        errdefer machines.deinit();
        const machine_id = machines.items[0].id;
        var sessions = try client.machine(machine_id).listSessions();
        errdefer sessions.deinit();
        const session_id = sessions.items[0].id;
        var workspaces = try client
            .machine(machine_id)
            .session(session_id)
            .listWorkspaces();
        errdefer workspaces.deinit();
        var ping_result = try client
            .machine(machine_id)
            .session(session_id)
            .ping();
        errdefer ping_result.deinit();

        var refreshed_machine = try client
            .machine(machine_id)
            .refresh();
        defer refreshed_machine.deinit();
        try std.testing.expectEqualStrings(
            "local",
            refreshed_machine.value.name,
        );
        var refreshed_session = try client
            .machine(machine_id)
            .session(session_id)
            .refresh();
        defer refreshed_session.deinit();
        try std.testing.expectEqual(@as(u64, 9), refreshed_session.value.revision);
        var refreshed_workspace = try client
            .machine(machine_id)
            .session(session_id)
            .workspace(workspaces.items[0].id)
            .refresh();
        defer refreshed_workspace.deinit();
        try std.testing.expectEqual(@as(u32, 1), refreshed_workspace.value.index);

        var renamed = try client
            .machine(machine_id)
            .session(session_id)
            .workspace(workspaces.items[0].id)
            .rename(
            "duplicate",
            try MutationOptions.withKey("typed-rename"),
        );
        defer renamed.deinit();
        try std.testing.expectEqualStrings("duplicate", renamed.value.name);
        var created = try client
            .machine(machine_id)
            .session(session_id)
            .createWorkspace(
            .{ .name = "created", .initial_content = .empty },
            try MutationOptions.withKey("typed-create"),
        );
        defer created.deinit();
        switch (created.value) {
            .workspace => |path| try std.testing.expectEqualStrings(
                "ws_33333333333333333333333333333333",
                path.workspace_id.slice(),
            ),
            else => return error.ExpectedWorkspacePath,
        }
        var closed = try client
            .machine(machine_id)
            .session(session_id)
            .workspace(workspaces.items[0].id)
            .close(try MutationOptions.withKey("typed-close"));
        defer closed.deinit();

        break :blk .{
            .machines = machines,
            .sessions = sessions,
            .workspaces = workspaces,
            .ping = ping_result,
        };
    };
    defer catalog.machines.deinit();
    defer catalog.sessions.deinit();
    defer catalog.workspaces.deinit();
    defer catalog.ping.deinit();

    try std.testing.expectEqual(@as(usize, 1), catalog.machines.items.len);
    try std.testing.expectEqual(@as(usize, 1), catalog.sessions.items.len);
    try std.testing.expectEqual(@as(usize, 2), catalog.workspaces.items.len);
    try std.testing.expectEqualStrings(
        "duplicate",
        catalog.workspaces.items[0].name,
    );
    try std.testing.expectEqualStrings(
        "duplicate",
        catalog.workspaces.items[1].name,
    );
    try std.testing.expect(
        !std.mem.eql(
            u8,
            catalog.workspaces.items[0].id.slice(),
            catalog.workspaces.items[1].id.slice(),
        ),
    );
    try std.testing.expect(catalog.ping.value.alive);
    try std.testing.expectEqual(
        @as(u64, 9),
        catalog.ping.value.cursor.revision,
    );
}

test "remaining catalog controls and rename aliases are typed" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .typed_catalog,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();

    const client_id = try ConnectedClientId.parse(
        "client_99999999999999999999999999999999",
    );
    const connected_client = client.connectedClient(client_id);
    var metadata = try connected_client.updateMetadata(.{
        .name = .{ .set = "sdk-client" },
    });
    defer metadata.deinit();
    try std.testing.expectEqualStrings(
        "sdk-client",
        metadata.value.name.?,
    );
    try std.testing.expectEqualStrings(
        "unix",
        metadata.value.transport.wireName(),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        metadata.value.attached_terminal_ids.len,
    );
    try std.testing.expectEqual(
        @as(?u16, 120),
        metadata.value.sizes[0].cols,
    );

    var cell_pixels = try connected_client.setCellPixels(9, 18);
    defer cell_pixels.deinit();
    try std.testing.expectEqual(
        @as(u32, 9),
        cell_pixels.value.width_px,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        cell_pixels.value.resized_terminals.len,
    );
    try std.testing.expectEqualStrings(
        "not attached",
        cell_pixels.value.failures[0].reason,
    );

    const browser_id = try BrowserId.parse(
        "browser_88888888888888888888888888888888",
    );
    const browser = client.browser(browser_id);
    var navigated = try browser.navigate(
        "https://cmux.dev/sdk",
        try MutationOptions.withKey("typed-browser-navigate"),
    );
    defer navigated.deinit();
    try std.testing.expectEqualStrings(
        "https://cmux.dev/sdk",
        navigated.value.url,
    );
    try std.testing.expectEqualStrings(
        "live",
        navigated.value.status.wireName(),
    );
    var browser_size = try browser.resizeBrowserViewer(1440, 900);
    defer browser_size.deinit();
    try std.testing.expect(browser_size.value.accepted);
    try std.testing.expectEqual(
        @as(u32, 1440),
        browser_size.value.size.width_px,
    );

    const screen_id = try ScreenId.parse(
        "screen_55555555555555555555555555555555",
    );
    const screen = client.screen(screen_id);
    var renamed_screen = try screen.rename(
        "screen-name",
        try MutationOptions.withKey("typed-screen-rename"),
    );
    defer renamed_screen.deinit();
    try std.testing.expectEqualStrings(
        "screen-name",
        renamed_screen.value.name.?,
    );
    switch (renamed_screen.value.layout.root.*) {
        .leaf => |leaf| try std.testing.expectEqual(
            @as(usize, 1),
            leaf.tab_ids.len,
        ),
        else => return error.ExpectedLayoutLeaf,
    }
    var cleared_screen = try screen.clearName(
        try MutationOptions.withKey("typed-screen-clear"),
    );
    defer cleared_screen.deinit();

    const pane_id = try PaneId.parse(
        "pane_66666666666666666666666666666666",
    );
    const pane = client.pane(pane_id);
    var renamed_pane = try pane.rename(
        "pane-name",
        try MutationOptions.withKey("typed-pane-rename"),
    );
    defer renamed_pane.deinit();
    try std.testing.expect(!renamed_pane.value.zoomed);
    var cleared_pane = try pane.clearName(
        try MutationOptions.withKey("typed-pane-clear"),
    );
    defer cleared_pane.deinit();

    const tab_id = try TabId.parse(
        "tab_77777777777777777777777777777777",
    );
    const tab = client.tab(tab_id);
    var renamed_tab = try tab.rename(
        "tab-name",
        try MutationOptions.withKey("typed-tab-rename"),
    );
    defer renamed_tab.deinit();
    try std.testing.expectEqualStrings(
        "terminal",
        renamed_tab.value.content_kind.wireName(),
    );
    try std.testing.expectEqualStrings(
        "term_0123456789abcdef0123456789abcdef",
        renamed_tab.value.content_id.slice(),
    );
    var cleared_tab = try tab.clearName(
        try MutationOptions.withKey("typed-tab-clear"),
    );
    defer cleared_tab.deinit();

    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, shared.output.items, "\"name\":null"),
    );
}

test "typed terminal reads controls and empty mutation receipts decode" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .typed_catalog,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const terminal = client.terminal(terminal_id);

    var screen = try terminal.readScreen();
    defer screen.deinit();
    try std.testing.expectEqualStrings("prompt$ ", screen.value.text);
    try std.testing.expectEqual(@as(u16, 120), screen.value.cols);
    try std.testing.expect(screen.value.cursor_visible);
    const future = screen.value.extra.?.get("future").?;
    try std.testing.expectEqualStrings("kept", future.string);

    var state = try terminal.readState();
    defer state.deinit();
    try std.testing.expectEqualStrings("aGVsbG8=", state.value.state_base64);
    try std.testing.expectEqualStrings("hello", state.value.state);

    var history = try terminal.readHistory(.{
        .before = 50,
        .limit = 2,
        .styled = true,
    });
    defer history.deinit();
    try std.testing.expectEqual(@as(u64, 41), history.value.start);
    try std.testing.expectEqual(@as(?u64, 43), history.value.next);
    try std.testing.expectEqual(@as(usize, 1), history.value.rows.len);
    const run = history.value.rows[0].runs[0];
    try std.testing.expectEqualStrings("hello", run.text);
    try std.testing.expectEqualStrings("#112233", run.fg.?);
    try std.testing.expectEqual(@as(u32, 5), run.attrs);
    try std.testing.expectEqualStrings(
        "curly",
        run.underline.?.wireName(),
    );

    var waited = try terminal.waitFor("ready", 2_000);
    defer waited.deinit();
    try std.testing.expect(waited.value.matched);
    try std.testing.expectEqualStrings("ready", waited.value.text);

    var copied = try terminal.copy(.selection);
    defer copied.deinit();
    try std.testing.expectEqualStrings(
        "selection",
        copied.value.mode.wireName(),
    );
    try std.testing.expectEqualStrings("copied", copied.value.text);

    var process = try terminal.processInfo();
    defer process.deinit();
    try std.testing.expectEqual(@as(u32, 123), process.value.pid);
    try std.testing.expectEqualStrings("/bin/zsh", process.value.executable.?);
    try std.testing.expectEqualStrings("zsh", process.value.argv[0]);
    try std.testing.expectEqual(@as(u32, 125), process.value.children[1]);

    var resized = try terminal.resizeTerminalViewer(100, 30);
    defer resized.deinit();
    try std.testing.expect(resized.value.accepted);
    try std.testing.expectEqual(@as(u16, 100), resized.value.size.cols);

    var released = try terminal.releaseTerminalViewer();
    defer released.deinit();
    var cleared = try terminal.clearHistory(
        try MutationOptions.withKey("typed-history-clear"),
    );
    defer cleared.deinit();
    try std.testing.expectEqual(@as(u64, 10), cleared.revision);

    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"before\":\"50\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"limit\":2",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"styled\":true",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"timeout_ms\":\"2000\"",
        ) != null,
    );
}

test "typed terminal decoders reject malformed and retain future enums" {
    var malformed = try raw.wire.parse(
        std.testing.allocator,
        "{\"text\":\"bad\",\"cols\":0,\"rows\":1," ++
            "\"cursor_row\":0,\"cursor_col\":0," ++
            "\"cursor_visible\":true}",
        .{},
    );
    const malformed_value = malformed.value;
    const malformed_result = OwnedResult{
        .owned = malformed,
        .value = malformed_value,
    };
    malformed = undefined;
    try std.testing.expectError(
        error.IntegerOutOfRange,
        decodeOwnedSimpleResult(
            TerminalScreenResult,
            malformed_result,
        ),
    );

    var future = try raw.wire.parse(
        std.testing.allocator,
        "{\"mode\":\"future-copy\",\"text\":\"owned\"}",
        .{},
    );
    const future_value = future.value;
    const future_result = OwnedResult{
        .owned = future,
        .value = future_value,
    };
    future = undefined;
    var decoded = try decodeOwnedSimpleResult(
        TerminalCopyResult,
        future_result,
    );
    defer decoded.deinit();
    switch (decoded.value.mode) {
        .unknown => |value| try std.testing.expectEqualStrings(
            "future-copy",
            value,
        ),
        else => return error.ExpectedUnknownCopyMode,
    }
}

test "typed catalogs reject malformed snapshots without leaking ownership" {
    var parsed = try raw.wire.parse(
        std.testing.allocator,
        "[{\"id\":\"machine_11111111111111111111111111111111\"," ++
            "\"name\":7,\"origin\":\"local\",\"status\":\"running\"," ++
            "\"connectable\":true,\"deleted\":false," ++
            "\"recoverable\":false}]",
        .{},
    );
    const value = parsed.value;
    const result = OwnedResult{
        .owned = parsed,
        .value = value,
    };
    parsed = undefined;
    try std.testing.expectError(
        error.ExpectedString,
        decodeTypedList(
            MachineSnapshot,
            std.testing.allocator,
            result,
            "machines",
        ),
    );
}

test "dropped mutation response retains supplied key without retry" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .dropped_mutation_disconnect,
    };
    defer shared.deinit();

    var uncertain = blk: {
        const connection = try fakeConnection(
            std.testing.allocator,
            &shared,
        );
        var client = Client.init(
            std.testing.allocator,
            connection,
            .{},
        );
        defer client.deinit();
        const workspace_id = try WorkspaceId.parse(
            "ws_0123456789abcdef0123456789abcdef",
        );
        try std.testing.expectError(
            error.MutationTransportUncertain,
            client.workspace(workspace_id).rename(
                "possibly-committed",
                try MutationOptions.withKey("supplied-uncertain-key"),
            ),
        );
        try std.testing.expect(client.lastResourceError() == null);
        const borrowed = client.lastMutationTransportUncertain().?;
        try std.testing.expectEqual(
            Operation.workspace_rename,
            borrowed.operation,
        );
        try std.testing.expectEqual(
            MutationTransportCause.connection_closed,
            borrowed.cause,
        );
        try std.testing.expectEqualStrings(
            "supplied-uncertain-key",
            borrowed.idempotency_key,
        );
        try std.testing.expectEqualStrings(
            "inspect_state_then_retry_with_new_key",
            borrowed.recovery.wireName(),
        );
        break :blk client.takeMutationTransportUncertain() orelse
            return error.MissingMutationTransportUncertain;
    };
    defer uncertain.deinit();

    try std.testing.expectEqualStrings(
        "supplied-uncertain-key",
        uncertain.value.idempotency_key,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"operation\":\"workspace.rename\"",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"idempotency_key\":\"supplied-uncertain-key\"",
        ),
    );
}

test "dropped mutation timeout retains exact generated key" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .dropped_mutation_timeout,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const workspace_id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );
    const options = MutationOptions.random();
    try std.testing.expectError(
        error.MutationTransportUncertain,
        client.workspace(workspace_id).rename(
            "possibly-committed",
            options,
        ),
    );
    const borrowed = client.lastMutationTransportUncertain().?;
    try std.testing.expectEqual(
        MutationTransportCause.timeout,
        borrowed.cause,
    );
    try std.testing.expectEqualStrings(
        options.key(),
        borrowed.idempotency_key,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"operation\":\"workspace.rename\"",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            options.key(),
        ),
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
    const details = switch (failure.details) {
        .mutation_indeterminate => |value| value,
        else => return error.ExpectedMutationIndeterminateDetails,
    };
    try std.testing.expectEqualStrings(
        "indeterminate-test-key",
        details.idempotency_key,
    );
    try std.testing.expectEqualStrings(
        "workspace.rename",
        details.operation,
    );
    try std.testing.expectEqualStrings(
        "inspect_state_then_retry_with_new_key",
        details.recovery.wireName(),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, shared.output.items, "idempotency_key"),
    );
}

test "catalog error details decode every declared shape" {
    const DetailTag = std.meta.Tag(ResourceErrorDetails);
    const Fixture = struct {
        code: []const u8,
        details: []const u8,
        tag: DetailTag,
    };
    const fixtures = [_]Fixture{
        .{
            .code = "authority.denied",
            .details = "{\"operation\":\"workspace.list\"}",
            .tag = .authority_denied,
        },
        .{
            .code = "confirmation.required",
            .details = "{\"revision\":\"3\",\"closes_panes\":[" ++
                "\"pane_11111111111111111111111111111111\"]}",
            .tag = .confirmation_required,
        },
        .{
            .code = "cursor.gap",
            .details = "{\"requested\":{\"generation\":\"g\"," ++
                "\"revision\":\"1\"},\"current\":{\"generation\":\"g\"," ++
                "\"revision\":\"3\"},\"oldest_revision\":\"2\"}",
            .tag = .cursor_gap,
        },
        .{
            .code = "cursor.invalid",
            .details = "{\"requested\":{\"generation\":\"old\"," ++
                "\"revision\":\"1\"},\"current\":{\"generation\":\"new\"," ++
                "\"revision\":\"1\"},\"reason\":\"generation changed\"}",
            .tag = .cursor_invalid,
        },
        .{
            .code = "idempotency.conflict",
            .details = "{\"idempotency_key\":\"key\"," ++
                "\"committed_operation\":\"workspace.rename\"}",
            .tag = .idempotency_conflict,
        },
        .{
            .code = "local.io",
            .details = "{\"path\":\"/tmp/socket\",\"reason\":\"closed\"}",
            .tag = .local_io,
        },
        .{
            .code = "mutation.indeterminate",
            .details = "{\"idempotency_key\":\"key\"," ++
                "\"operation\":\"workspace.rename\",\"recovery\":" ++
                "\"inspect_state_then_retry_with_new_key\"}",
            .tag = .mutation_indeterminate,
        },
        .{
            .code = "operation.failed",
            .details = "{\"operation\":\"workspace.run\"," ++
                "\"reason\":\"failed\",\"extra\":{\"exit_code\":2}}",
            .tag = .operation_failed,
        },
        .{
            .code = "resource.not_found",
            .details = "{\"scope\":\"workspace\",\"id\":" ++
                "\"ws_11111111111111111111111111111111\"}",
            .tag = .resource_not_found,
        },
        .{
            .code = "revision.conflict",
            .details = "{\"expected\":\"4\",\"actual\":\"5\"}",
            .tag = .revision_conflict,
        },
        .{
            .code = "selector.ambiguous",
            .details = "{\"scope\":\"workspace\"," ++
                "\"selector\":\"name:duplicate\",\"candidates\":[" ++
                "\"ws_11111111111111111111111111111111\"," ++
                "\"ws_22222222222222222222222222222222\"]}",
            .tag = .selector_ambiguous,
        },
        .{
            .code = "selector.invalid",
            .details = "{\"scope\":\"workspace\"," ++
                "\"selector\":\"invalid\",\"reason\":\"bad syntax\"}",
            .tag = .selector_invalid,
        },
        .{
            .code = "selector.not_found",
            .details = "{\"scope\":\"workspace\"," ++
                "\"selector\":\"name:missing\"}",
            .tag = .selector_not_found,
        },
        .{
            .code = "selector.wrong_parent",
            .details = "{\"scope\":\"pane\",\"selector\":" ++
                "\"pane_11111111111111111111111111111111\"," ++
                "\"parent_scope\":\"screen\",\"expected_parent\":" ++
                "\"screen_11111111111111111111111111111111\"," ++
                "\"actual_parent\":" ++
                "\"screen_22222222222222222222222222222222\"}",
            .tag = .selector_wrong_parent,
        },
        .{
            .code = "transport.closed",
            .details = "{\"reason\":\"peer closed\"}",
            .tag = .transport_closed,
        },
        .{
            .code = "validation.invalid",
            .details = "{\"field\":\"name\",\"reason\":\"too long\"}",
            .tag = .validation_invalid,
        },
    };

    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();

    for (fixtures) |fixture| {
        const encoded = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"code\":\"{s}\",\"message\":\"fixture\"," ++
                "\"details\":{s},\"retryable\":false}}",
            .{ fixture.code, fixture.details },
        );
        defer std.testing.allocator.free(encoded);
        var parsed = try raw.wire.parse(
            std.testing.allocator,
            encoded,
            .{},
        );
        try client.setError(parsed.value);
        parsed.deinit();
        var owned = client.takeResourceError() orelse
            return error.MissingResourceError;
        defer owned.deinit();
        try std.testing.expectEqual(
            fixture.tag,
            std.meta.activeTag(owned.value.details),
        );
    }
}

test "malformed known and future error details remain owned and explicit" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    errdefer client.deinit();

    var malformed_source = try raw.wire.parse(
        std.testing.allocator,
        "{\"code\":\"selector.ambiguous\",\"message\":\"bad\"," ++
            "\"details\":{\"candidates\":[" ++
            "\"ws_11111111111111111111111111111111\"]}," ++
            "\"retryable\":false}",
        .{},
    );
    try client.setError(malformed_source.value);
    malformed_source.deinit();
    var malformed = client.takeResourceError() orelse
        return error.MissingResourceError;
    defer malformed.deinit();
    switch (malformed.value.details) {
        .malformed => {},
        else => return error.ExpectedMalformedResourceErrorDetails,
    }

    var future_source = try raw.wire.parse(
        std.testing.allocator,
        "{\"code\":\"future.quota\",\"message\":\"future\"," ++
            "\"details\":{\"limit\":\"9\",\"auth\":{\"token\":" ++
            "\"future-secret\"}},\"retryable\":true}",
        .{},
    );
    try client.setError(future_source.value);
    future_source.deinit();
    var future = client.takeResourceError() orelse
        return error.MissingResourceError;
    client.deinit();
    defer future.deinit();

    const unknown = switch (future.value.details) {
        .unknown => |value| value.raw,
        else => return error.ExpectedUnknownResourceErrorDetails,
    };
    const details = try detailObject(unknown);
    const auth = try detailObject(
        details.get("auth") orelse return error.MissingField,
    );
    try std.testing.expectEqualStrings(
        "[REDACTED]",
        try objectString(auth, "token"),
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

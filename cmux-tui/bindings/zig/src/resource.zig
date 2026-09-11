const std = @import("std");
const raw = @import("raw.zig");

pub const OperationClass = enum {
    read,
    mutation,
    stream_open,
    connection_control,
};

const FacadeOwner = enum {
    client,
    machine,
    session,
    workspace,
    screen,
    pane,
    tab,
    terminal,
    browser,
    connected_client,
    pairing_request,
    frontend_projection,
    sidebar_view,
    session_stream,
    terminal_stream,
    browser_stream,
};

const FacadeBinding = struct {
    owner: FacadeOwner,
    method: []const u8,
};

/// Handwritten intent-layer inventory. `terminal.create` remains raw-only.
pub const Operation = enum {
    machine_list,
    machine_get,
    session_list,
    session_open,
    session_get,
    session_snapshot,
    session_creation_resolve,
    session_events,
    session_journal_subscribe,
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
    request_cancel,
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
    terminal_wait_exit,
    terminal_copy,
    terminal_process_get,
    terminal_renderer_grant_create,
    terminal_viewer_resize,
    terminal_viewer_release,
    terminal_viewport_scroll,
    terminal_move,
    terminal_project,
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
    stream_cancel,

    pub fn wireName(self: Operation) []const u8 {
        return switch (self) {
            .machine_list => "machine.list",
            .machine_get => "machine.get",
            .session_list => "session.list",
            .session_open => "session.open",
            .session_get => "session.get",
            .session_snapshot => "session.snapshot",
            .session_creation_resolve => "session.creation.resolve",
            .session_events => "session.events",
            .session_journal_subscribe => "session.journal.subscribe",
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
            .request_cancel => "request.cancel",
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
            .terminal_wait_exit => "terminal.wait_exit",
            .terminal_copy => "terminal.copy",
            .terminal_process_get => "terminal.process.get",
            .terminal_renderer_grant_create => "terminal.renderer_grant.create",
            .terminal_viewer_resize => "terminal.viewer.resize",
            .terminal_viewer_release => "terminal.viewer.release",
            .terminal_viewport_scroll => "terminal.viewport.scroll",
            .terminal_move => "terminal.move",
            .terminal_project => "terminal.project",
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
            .stream_cancel => "stream.cancel",
        };
    }

    pub fn class(self: Operation) OperationClass {
        return switch (self) {
            .session_events,
            .session_journal_subscribe,
            .terminal_attach,
            .browser_attach,
            .sidebar_view_attach,
            => .stream_open,

            .request_cancel,
            .stream_cancel,
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
            .session_creation_resolve,
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
            .terminal_wait_exit,
            .terminal_copy,
            .terminal_process_get,
            .browser_list,
            .browser_get,
            .notification_list,
            .agent_list,
            .sidebar_view_get,
            => .read,

            else => .mutation,
        };
    }

    fn requiresMachine(self: Operation) bool {
        return switch (self) {
            .machine_list,
            .request_cancel,
            => false,
            else => true,
        };
    }

    fn requiresSession(self: Operation) bool {
        return switch (self) {
            .machine_list,
            .machine_get,
            .session_list,
            .request_cancel,
            => false,
            else => true,
        };
    }

    fn supportsExpectedRevision(self: Operation) bool {
        return self.class() == .mutation;
    }

    fn facadeBinding(self: Operation) FacadeBinding {
        return switch (self) {
            .machine_list => .{ .owner = .client, .method = "listMachines" },
            .machine_get => .{ .owner = .machine, .method = "refresh" },
            .session_list => .{ .owner = .machine, .method = "listSessions" },
            .session_open => .{ .owner = .machine, .method = "openSession" },
            .session_get => .{ .owner = .session, .method = "refresh" },
            .session_snapshot => .{ .owner = .session, .method = "fullSnapshot" },
            .session_creation_resolve => .{ .owner = .session, .method = "resolveCreation" },
            .session_events => .{ .owner = .session, .method = "eventsFrom" },
            .session_journal_subscribe => .{ .owner = .session, .method = "journal" },
            .session_ping => .{ .owner = .session, .method = "ping" },
            .session_shutdown => .{ .owner = .session, .method = "shutdown" },
            .session_reload_config => .{ .owner = .session, .method = "reloadConfig" },
            .session_terminal_defaults_update => .{ .owner = .session, .method = "updateTerminalDefaults" },
            .client_list => .{ .owner = .session, .method = "listClients" },
            .client_get => .{ .owner = .connected_client, .method = "refresh" },
            .client_metadata_update => .{ .owner = .connected_client, .method = "updateMetadata" },
            .client_sizing_set => .{ .owner = .connected_client, .method = "setSizing" },
            .client_sizing_release => .{ .owner = .connected_client, .method = "releaseSizing" },
            .client_cell_pixels_set => .{ .owner = .connected_client, .method = "setCellPixels" },
            .client_detach => .{ .owner = .connected_client, .method = "detachClient" },
            .session_window_title_set => .{ .owner = .session, .method = "setWindowTitle" },
            .session_window_title_clear => .{ .owner = .session, .method = "clearWindowTitle" },
            .pairing_request_list => .{ .owner = .session, .method = "listPairingRequests" },
            .pairing_request_resolve => .{ .owner = .pairing_request, .method = "resolvePairing" },
            .request_cancel => .{ .owner = .client, .method = "cancelRequest" },
            .frontend_projection_get => .{ .owner = .frontend_projection, .method = "refresh" },
            .frontend_projection_put => .{ .owner = .frontend_projection, .method = "putProjection" },
            .workspace_list => .{ .owner = .session, .method = "listWorkspaces" },
            .workspace_get => .{ .owner = .workspace, .method = "refresh" },
            .workspace_create => .{ .owner = .session, .method = "createWorkspace" },
            .workspace_rename => .{ .owner = .workspace, .method = "rename" },
            .workspace_move => .{ .owner = .workspace, .method = "moveWorkspace" },
            .workspace_focus => .{ .owner = .workspace, .method = "focusWorkspace" },
            .workspace_close => .{ .owner = .workspace, .method = "close" },
            .workspace_run => .{ .owner = .workspace, .method = "run" },
            .workspace_layout_apply => .{ .owner = .workspace, .method = "applyLayout" },
            .screen_list => .{ .owner = .workspace, .method = "listScreens" },
            .screen_get => .{ .owner = .screen, .method = "refresh" },
            .screen_create => .{ .owner = .workspace, .method = "createScreen" },
            .screen_rename => .{ .owner = .screen, .method = "rename" },
            .screen_focus => .{ .owner = .screen, .method = "focusScreen" },
            .screen_close => .{ .owner = .screen, .method = "close" },
            .screen_layout_export => .{ .owner = .screen, .method = "exportLayout" },
            .screen_layout_undo => .{ .owner = .screen, .method = "undoLayout" },
            .pane_list => .{ .owner = .screen, .method = "listPanes" },
            .pane_get => .{ .owner = .pane, .method = "refresh" },
            .pane_create => .{ .owner = .screen, .method = "createPane" },
            .pane_split => .{ .owner = .pane, .method = "splitPane" },
            .pane_rename => .{ .owner = .pane, .method = "rename" },
            .pane_focus => .{ .owner = .pane, .method = "focusPane" },
            .pane_focus_direction => .{ .owner = .pane, .method = "focusDirection" },
            .pane_neighbor_get => .{ .owner = .pane, .method = "neighbor" },
            .pane_swap => .{ .owner = .pane, .method = "swapPane" },
            .pane_zoom => .{ .owner = .pane, .method = "zoomPane" },
            .pane_split_ratio_set => .{ .owner = .pane, .method = "setSplitRatio" },
            .pane_viewport_width_set => .{ .owner = .pane, .method = "setViewportWidth" },
            .pane_close => .{ .owner = .pane, .method = "close" },
            .pane_run => .{ .owner = .pane, .method = "run" },
            .tab_list => .{ .owner = .pane, .method = "listTabs" },
            .tab_get => .{ .owner = .tab, .method = "refresh" },
            .tab_create_terminal => .{ .owner = .pane, .method = "createTerminalTab" },
            .tab_create_browser => .{ .owner = .pane, .method = "createBrowserTab" },
            .tab_rename => .{ .owner = .tab, .method = "rename" },
            .tab_move => .{ .owner = .tab, .method = "moveTab" },
            .tab_focus => .{ .owner = .tab, .method = "focusTab" },
            .tab_close => .{ .owner = .tab, .method = "close" },
            .terminal_list => .{ .owner = .session, .method = "listTerminals" },
            .terminal_get => .{ .owner = .terminal, .method = "refresh" },
            .terminal_input_write => .{ .owner = .terminal, .method = "writeBytes" },
            .terminal_input_keys => .{ .owner = .terminal, .method = "sendKeys" },
            .terminal_input_mouse => .{ .owner = .terminal, .method = "sendMouse" },
            .terminal_input_focus => .{ .owner = .terminal, .method = "setInputFocus" },
            .terminal_screen_read => .{ .owner = .terminal, .method = "readScreen" },
            .terminal_state_read => .{ .owner = .terminal, .method = "readState" },
            .terminal_history_read => .{ .owner = .terminal, .method = "readHistory" },
            .terminal_history_clear => .{ .owner = .terminal, .method = "clearHistory" },
            .terminal_wait => .{ .owner = .terminal, .method = "waitFor" },
            .terminal_wait_exit => .{ .owner = .terminal, .method = "waitForExit" },
            .terminal_copy => .{ .owner = .terminal, .method = "copy" },
            .terminal_process_get => .{ .owner = .terminal, .method = "processInfo" },
            .terminal_renderer_grant_create => .{ .owner = .terminal, .method = "rendererGrantWith" },
            .terminal_viewer_resize => .{ .owner = .terminal_stream, .method = "resizeTerminalViewer" },
            .terminal_viewer_release => .{ .owner = .terminal_stream, .method = "releaseTerminalViewer" },
            .terminal_viewport_scroll => .{ .owner = .terminal, .method = "scroll" },
            .terminal_move => .{ .owner = .terminal, .method = "moveTerminal" },
            .terminal_project => .{ .owner = .terminal, .method = "projectTerminal" },
            .terminal_attach => .{ .owner = .terminal, .method = "attachTerminalWith" },
            .terminal_close => .{ .owner = .terminal, .method = "close" },
            .browser_list => .{ .owner = .session, .method = "listBrowsers" },
            .browser_get => .{ .owner = .browser, .method = "refresh" },
            .browser_navigate => .{ .owner = .browser, .method = "navigate" },
            .browser_back => .{ .owner = .browser, .method = "browserBack" },
            .browser_forward => .{ .owner = .browser, .method = "browserForward" },
            .browser_reload => .{ .owner = .browser, .method = "reloadBrowser" },
            .browser_activate => .{ .owner = .browser, .method = "activateBrowser" },
            .browser_input_key => .{ .owner = .browser, .method = "sendBrowserKey" },
            .browser_input_text => .{ .owner = .browser, .method = "sendBrowserText" },
            .browser_input_mouse => .{ .owner = .browser, .method = "sendBrowserMouse" },
            .browser_input_wheel => .{ .owner = .browser, .method = "sendBrowserWheel" },
            .browser_viewer_resize => .{ .owner = .browser_stream, .method = "resizeBrowserViewer" },
            .browser_viewer_release => .{ .owner = .browser_stream, .method = "releaseBrowserViewer" },
            .browser_attach => .{ .owner = .browser, .method = "attachBrowserWith" },
            .browser_close => .{ .owner = .browser, .method = "close" },
            .notification_list => .{ .owner = .session, .method = "listNotifications" },
            .notification_create => .{ .owner = .session, .method = "createNotification" },
            .agent_list => .{ .owner = .session, .method = "listAgents" },
            .agent_report => .{ .owner = .session, .method = "reportAgent" },
            .sidebar_view_get => .{ .owner = .sidebar_view, .method = "refresh" },
            .sidebar_view_ensure => .{ .owner = .session, .method = "ensureSidebarView" },
            .sidebar_view_attach => .{ .owner = .sidebar_view, .method = "attachSidebar" },
            .sidebar_view_input => .{ .owner = .sidebar_view, .method = "sendSidebarInput" },
            .sidebar_view_resize => .{ .owner = .sidebar_view, .method = "resizeSidebar" },
            .sidebar_view_reload => .{ .owner = .sidebar_view, .method = "reloadSidebar" },
            .stream_cancel => .{ .owner = .session_stream, .method = "cancel" },
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
        try validateIdempotencyKey(provided_key);
        var result: MutationOptions = .{
            .len = @intCast(provided_key.len),
        };
        @memcpy(result.bytes[0..provided_key.len], provided_key);
        return result;
    }

    fn validate(self: *const MutationOptions) !void {
        if (self.len == 0 or self.len > self.bytes.len) {
            return error.InvalidIdempotencyKey;
        }
        try validateIdempotencyKey(self.bytes[0..self.len]);
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

fn validateIdempotencyKey(provided_key: []const u8) !void {
    if (provided_key.len == 0 or provided_key.len > 128) {
        return error.InvalidIdempotencyKey;
    }
    var iterator = (std.unicode.Utf8View.init(provided_key) catch {
        return error.InvalidIdempotencyKey;
    }).iterator();
    var has_non_whitespace = false;
    while (iterator.nextCodepoint()) |codepoint| {
        if (unicodeControl(codepoint)) {
            return error.InvalidIdempotencyKey;
        }
        has_non_whitespace = has_non_whitespace or
            !unicodeWhitespace(codepoint);
    }
    if (!has_non_whitespace) return error.InvalidIdempotencyKey;
}

fn unicodeWhitespace(codepoint: u21) bool {
    return (codepoint >= 0x0009 and codepoint <= 0x000D) or
        codepoint == 0x0020 or codepoint == 0x0085 or
        codepoint == 0x00A0 or codepoint == 0x1680 or
        (codepoint >= 0x2000 and codepoint <= 0x200A) or
        codepoint == 0x2028 or codepoint == 0x2029 or
        codepoint == 0x202F or codepoint == 0x205F or
        codepoint == 0x3000;
}

fn unicodeControl(codepoint: u21) bool {
    return codepoint <= 0x001F or
        (codepoint >= 0x007F and codepoint <= 0x009F);
}

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

pub const JournalStart = enum {
    tail,
    beginning,

    pub fn wireName(self: JournalStart) []const u8 {
        return @tagName(self);
    }
};

pub const JournalClass = enum {
    state,
    observation,
    effect,
    checkpoint,

    pub fn wireName(self: JournalClass) []const u8 {
        return @tagName(self);
    }
};

pub const JournalReplayPolicy = enum {
    required,
    advisory,
    never,
};

pub const JournalSensitivity = enum {
    public,
    metadata,
    sensitive,
    secret,

    pub fn wireName(self: JournalSensitivity) []const u8 {
        return @tagName(self);
    }
};

pub const JournalSubjectFilter = struct {
    kind: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const JournalRegexField = enum {
    kind,
    subjects,
    payload,
    record,
    terminal_output,
};

pub const JournalRegexFilter = struct {
    pattern: []const u8,
    field: JournalRegexField = .record,
    case_sensitive: bool = true,
};

pub const JournalFilter = struct {
    kinds: []const []const u8 = &.{},
    classes: []const JournalClass = &.{},
    subjects: []const JournalSubjectFilter = &.{},
    max_sensitivity: ?JournalSensitivity = null,
    regex: ?JournalRegexFilter = null,
};

pub const SessionJournalOptions = struct {
    cursor: ?Cursor = null,
    start: ?JournalStart = null,
    follow: ?bool = null,
    filter: JournalFilter = .{},
};

pub const JournalProducer = struct {
    kind: []const u8,
    id: []const u8,
};

pub const JournalAuthority = struct {
    principal_id: []const u8,
    lease_id: []const u8,
    generation: []const u8,
    role: []const u8,
};

pub const JournalSubject = struct {
    kind: []const u8,
    id: []const u8,
};

pub const SessionJournalRecord = struct {
    sequence: u64,
    event_id: []const u8,
    schema_version: u32,
    kind: []const u8,
    journal_class: JournalClass,
    replay: JournalReplayPolicy,
    occurred_at_ms: u64,
    committed_at_ms: u64,
    producer: JournalProducer,
    authority: ?JournalAuthority,
    causation_id: ?[]const u8,
    correlation_id: ?[]const u8,
    causation_depth: u16,
    subjects: []const JournalSubject,
    sensitivity: JournalSensitivity,
    payload: raw.wire.Value,
    resource_revision: ?u64,
    previous_resource_revision: ?u64,
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

pub const ConfirmationRequiredDetails = struct {
    revision: u64,
    closes_panes: []const PaneId,
    confirmation_token: []const u8,
};

pub const CreationConflictDetails = struct {
    correlation_key: []const u8,
    existing_operation: []const u8,
    requested_operation: []const u8,
    existing_fingerprint: []const u8,
    requested_fingerprint: []const u8,
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
    /// `scope` is optional for compatibility with early protocol-v2 servers.
    scope: ?ErrorResourceScope,
    /// `selector` is optional for compatibility with early protocol-v2 servers.
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
    confirmation_required: ConfirmationRequiredDetails,
    creation_conflict: CreationConflictDetails,
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
    other,
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
    /// `timeout_ms` is the remaining stream-open deadline. Implementations
    /// must apply it while establishing the transport.
    openFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        timeout_ms: ?u32,
    ) anyerror!raw.transport.Connection,

    pub fn open(
        self: ConnectionFactory,
        allocator: std.mem.Allocator,
        timeout_ms: ?u32,
    ) !raw.transport.Connection {
        return self.openFn(self.context, allocator, timeout_ms);
    }
};

pub const Options = struct {
    session: []const u8 = "main",
    socket_path: ?[]const u8 = null,
    timeout_ms: ?u32 = 10_000,
    limits: raw.wire.Limits = .{},
    stream_factory: ?ConnectionFactory = null,
};

const TimeoutDeadline = struct {
    timer: ?std.time.Timer = null,
    timeout_ns: u64 = 0,

    fn start(timeout_ms: ?u32) !TimeoutDeadline {
        const milliseconds = timeout_ms orelse return .{};
        return .{
            .timer = try std.time.Timer.start(),
            .timeout_ns = @as(u64, milliseconds) * std.time.ns_per_ms,
        };
    }

    fn remainingNs(self: *TimeoutDeadline) !?u64 {
        const timer = if (self.timer) |*value| value else return null;
        const elapsed_ns = timer.read();
        if (elapsed_ns >= self.timeout_ns) return error.Timeout;
        return self.timeout_ns - elapsed_ns;
    }

    fn remainingMs(self: *TimeoutDeadline) !?u32 {
        const remaining_ns = (try self.remainingNs()) orelse return null;
        return @intCast(
            (remaining_ns - 1) / std.time.ns_per_ms + 1,
        );
    }
};

const RequestDispatch = enum {
    not_dispatched,
    write_started,
    payload_complete,
};

fn isSecretField(key: []const u8) bool {
    return std.mem.eql(u8, key, "token") or
        std.mem.eql(u8, key, "specifier") or
        std.mem.eql(u8, key, "credential") or
        std.mem.eql(u8, key, "secret") or
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
        .string => |text| blk: {
            if (text.len == 0 or
                (text.len > 1 and text[0] == '0'))
            {
                return error.InvalidDecimalString;
            }
            for (text) |byte| {
                if (byte < '0' or byte > '9') {
                    return error.InvalidDecimalString;
                }
            }
            break :blk std.fmt.parseInt(u64, text, 10);
        },
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
    return std.mem.eql(u8, code, "confirmation.required") or
        std.mem.eql(u8, code, "creation.conflict") or
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
    if (std.mem.eql(u8, code, "confirmation.required")) {
        try ensureOnlyFields(
            object,
            &.{ "confirmation_token", "revision", "closes_panes" },
        );
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
        const confirmation_token = try objectString(
            object,
            "confirmation_token",
        );
        if (confirmation_token.len == 0 or
            confirmation_token.len > 128)
        {
            return error.InvalidConfirmationToken;
        }
        return .{ .confirmation_required = .{
            .revision = try decimalU64(
                object.get("revision") orelse return error.MissingField,
            ),
            .closes_panes = panes,
            .confirmation_token = confirmation_token,
        } };
    }
    if (std.mem.eql(u8, code, "creation.conflict")) {
        try ensureOnlyFields(
            object,
            &.{
                "correlation_key",
                "existing_operation",
                "requested_operation",
                "existing_fingerprint",
                "requested_fingerprint",
            },
        );
        const correlation_key = try objectString(
            object,
            "correlation_key",
        );
        const existing_operation = try objectString(
            object,
            "existing_operation",
        );
        const requested_operation = try objectString(
            object,
            "requested_operation",
        );
        const existing_fingerprint = try objectString(
            object,
            "existing_fingerprint",
        );
        const requested_fingerprint = try objectString(
            object,
            "requested_fingerprint",
        );
        if (correlation_key.len == 0 or correlation_key.len > 128 or
            existing_operation.len == 0 or
            requested_operation.len == 0 or
            existing_fingerprint.len == 0 or
            requested_fingerprint.len == 0)
        {
            return error.InvalidCreationConflictDetails;
        }
        return .{ .creation_conflict = .{
            .correlation_key = correlation_key,
            .existing_operation = existing_operation,
            .requested_operation = requested_operation,
            .existing_fingerprint = existing_fingerprint,
            .requested_fingerprint = requested_fingerprint,
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
) MutationTransportCause {
    if (failure == error.Timeout) return .timeout;
    if (failure == error.ConnectionClosed) return .connection_closed;
    return .other;
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
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    request_admission_mutex: std.Thread.Mutex = .{},
    request_admission_condition: std.Thread.Condition = .{},
    request_active: bool = false,
    request_waiters: usize = 0,
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
        defer allocator.free(path);
        const Resolved = struct {
            connection: raw.transport.Connection,
            path: []u8,
        };
        const resolved: Resolved = if (options.socket_path == null and !(try raw.transport.hasSocketOverride())) blk: {
            const fallback = try raw.transport.connectResolvedWithLegacyFallback(
                allocator,
                path,
                options.session,
                options.timeout_ms,
            );
            break :blk .{ .connection = fallback.connection, .path = fallback.path };
        } else blk: {
            var connection = try raw.transport.connectUnixWithTimeout(allocator, path, options.timeout_ms);
            errdefer connection.deinit();
            const owned_path = try allocator.dupe(u8, path);
            break :blk .{ .connection = connection, .path = owned_path };
        };
        var connection = resolved.connection;
        const effective_path = resolved.path;
        errdefer connection.deinit();
        var result = init(allocator, connection, options);
        result.owned_socket_path = effective_path;
        return result;
    }

    pub fn close(self: *Client) void {
        self.close_mutex.lock();
        defer self.close_mutex.unlock();
        if (self.closed.swap(true, .acq_rel)) return;
        self.connection.close();
        self.request_admission_mutex.lock();
        defer self.request_admission_mutex.unlock();
        self.request_admission_condition.broadcast();
    }

    fn isClosed(self: *const Client) bool {
        return self.closed.load(.acquire);
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

    fn postDispatchFailure(
        self: *Client,
        operation: Operation,
        mutation: ?MutationOptions,
        failure: anyerror,
    ) anyerror {
        const options = mutation orelse return failure;
        self.setMutationTransportUncertain(
            operation,
            options.key(),
            mutationTransportCause(failure),
        ) catch |record_failure| return record_failure;
        return error.MutationTransportUncertain;
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

    fn acquireRequest(
        self: *Client,
        deadline: *TimeoutDeadline,
    ) !void {
        self.request_admission_mutex.lock();
        defer self.request_admission_mutex.unlock();
        if (self.isClosed()) return error.ConnectionClosed;
        var waiting = false;
        defer {
            if (waiting) self.request_waiters -= 1;
        }
        while (self.request_active) {
            if (self.isClosed()) return error.ConnectionClosed;
            if (!waiting) {
                self.request_waiters += 1;
                waiting = true;
            }
            if (try deadline.remainingNs()) |remaining_ns| {
                self.request_admission_condition.timedWait(
                    &self.request_admission_mutex,
                    remaining_ns,
                ) catch {};
            } else {
                self.request_admission_condition.wait(
                    &self.request_admission_mutex,
                );
            }
        }
        if (waiting) {
            self.request_waiters -= 1;
            waiting = false;
        }
        if (self.isClosed()) return error.ConnectionClosed;
        _ = deadline.remainingNs() catch |failure| {
            // A waiter can be signaled while the request permit is idle, then
            // expire before it reacquires this mutex. Hand the permit to the next
            // waiter instead of consuming the only wakeup.
            if (self.request_waiters > 0) {
                self.request_admission_condition.signal();
            }
            return failure;
        };
        self.request_active = true;
    }

    fn releaseRequest(self: *Client) void {
        self.request_admission_mutex.lock();
        defer self.request_admission_mutex.unlock();
        self.request_active = false;
        if (self.request_waiters > 0) {
            self.request_admission_condition.signal();
        }
    }

    fn sendRequest(
        self: *Client,
        request_id: []const u8,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
    ) !void {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        return self.sendRequestWithDeadline(
            request_id,
            operation,
            params,
            mutation,
            &deadline,
            null,
        );
    }

    fn sendRequestWithDeadline(
        self: *Client,
        request_id: []const u8,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
        deadline: *TimeoutDeadline,
        dispatch: ?*RequestDispatch,
    ) !void {
        if (dispatch) |state| state.* = .not_dispatched;
        if (self.isClosed()) return error.ConnectionClosed;
        if (mutation) |options| try options.validate();
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
            .{ .string = try allocator.dupe(u8, "cmux.protocol/2") },
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
        // No framing byte has reached the transport yet, so a deadline
        // failure here leaves the connection reusable.
        const payload_timeout = try deadline.remainingMs();
        // `Connection.writeAll` does not report how many bytes reached the
        // peer when it fails. Once it starts, mutation progress is unknown.
        if (dispatch) |state| state.* = .write_started;
        self.connection.writeAll(encoded, payload_timeout) catch |failure| {
            self.close();
            return failure;
        };
        // Rust's BufRead::lines accepts a final JSON record at EOF without a
        // newline. Once the complete payload is written, closing can cause the
        // peer to execute it, so a mutation response is no longer determinate.
        if (dispatch) |state| state.* = .payload_complete;
        const newline_timeout = deadline.remainingMs() catch |failure| {
            self.close();
            return failure;
        };
        self.connection.writeAll("\n", newline_timeout) catch |failure| {
            self.close();
            return failure;
        };
        _ = deadline.remainingMs() catch |failure| {
            self.close();
            return failure;
        };
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

    fn readMessageWithTimeout(
        self: *Client,
        timeout_ms: ?u32,
    ) !raw.wire.OwnedValue {
        var deadline = try TimeoutDeadline.start(timeout_ms);
        return self.readMessageWithDeadline(&deadline);
    }

    fn readMessageWithDeadline(
        self: *Client,
        deadline: *TimeoutDeadline,
    ) !raw.wire.OwnedValue {
        while (true) {
            const timeout_ms = try deadline.remainingMs();
            const maybe_frame = self.takeFrame() catch |failure| {
                self.close();
                return failure;
            };
            if (maybe_frame) |frame| {
                defer self.allocator.free(frame);
                if (frame.len == 0) {
                    self.close();
                    return error.EmptyFrame;
                }
                return raw.wire.parse(
                    self.allocator,
                    frame,
                    self.limits,
                ) catch |failure| {
                    self.close();
                    return failure;
                };
            }
            var chunk: [8192]u8 = undefined;
            const count = self.connection.read(
                &chunk,
                timeout_ms,
            ) catch |failure| {
                if (failure != error.Timeout) self.close();
                return failure;
            };
            if (count == 0) {
                self.close();
                return error.ConnectionClosed;
            }
            self.inbound.appendSlice(
                self.allocator,
                chunk[0..count],
            ) catch |failure| {
                self.close();
                return failure;
            };
        }
    }

    fn readMessage(self: *Client) !raw.wire.OwnedValue {
        return self.readMessageWithTimeout(self.timeout_ms);
    }

    fn cancelRequest(
        self: *Client,
        target_request_id: []const u8,
        target_operation: Operation,
    ) !void {
        errdefer self.close();
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const cancel_request_id = try self.requestId();
        defer self.allocator.free(cancel_request_id);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var params = raw.wire.Object.init(arena.allocator());
        try params.put(
            "request_id",
            .{
                .string = try arena.allocator().dupe(
                    u8,
                    target_request_id,
                ),
            },
        );
        try self.sendRequestWithDeadline(
            cancel_request_id,
            .request_cancel,
            .{ .object = params },
            null,
            &deadline,
            null,
        );

        var cancel_result: ?bool = null;
        var target_seen = false;
        while (true) {
            var message = try self.readMessageWithDeadline(&deadline);
            defer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const protocol = try objectString(object, "protocol");
            if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
                return error.InvalidProtocolEnvelope;
            }
            const envelope_type = try objectString(object, "type");
            if (!std.mem.eql(u8, envelope_type, "response")) {
                return error.UnexpectedStreamEnvelope;
            }
            const response_id = try objectString(object, "id");
            if (std.mem.eql(u8, response_id, target_request_id)) {
                if (target_seen) {
                    return error.DuplicateRequestResponse;
                }
                switch (try parseExactResponse(object)) {
                    .success => |result| switch (target_operation) {
                        .terminal_wait => _ = try decodeTerminalWaitResult(
                            result,
                        ),
                        .terminal_wait_exit => _ =
                            try decodeTerminalWaitExitResult(result),
                        else => {},
                    },
                    .failure => {},
                }
                target_seen = true;
            } else if (std.mem.eql(
                u8,
                response_id,
                cancel_request_id,
            )) {
                if (cancel_result != null) {
                    return error.DuplicateCancelResponse;
                }
                const result = switch (try parseExactResponse(object)) {
                    .success => |value| value,
                    .failure => return error.RequestCancelRejected,
                };
                const result_object = switch (result) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                try ensureOnlyFields(
                    result_object,
                    &.{"canceled"},
                );
                cancel_result = try objectBool(
                    result_object,
                    "canceled",
                );
            } else {
                return error.UnexpectedResponseId;
            }

            if (cancel_result) |canceled| {
                if (canceled) {
                    if (target_seen) {
                        return error.CanceledRequestResponded;
                    }
                    return;
                }
                if (target_seen) return;
            }
        }
    }

    fn callLocked(
        self: *Client,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
        deadline: *TimeoutDeadline,
    ) !OwnedResult {
        self.clearError();
        self.clearMutationTransportUncertain();
        const request_id = try self.requestId();
        defer self.allocator.free(request_id);
        var dispatch: RequestDispatch = .not_dispatched;
        self.sendRequestWithDeadline(
            request_id,
            operation,
            params,
            mutation,
            deadline,
            &dispatch,
        ) catch |failure| {
            if (dispatch != .not_dispatched) {
                if (mutation) |options| {
                    try self.setMutationTransportUncertain(
                        operation,
                        options.key(),
                        mutationTransportCause(failure),
                    );
                    return error.MutationTransportUncertain;
                }
            }
            return failure;
        };
        var close_on_error = true;
        errdefer if (close_on_error) self.close();
        while (true) {
            var message = self.readMessageWithDeadline(deadline) catch |failure| {
                if ((operation == .terminal_wait or
                    operation == .terminal_wait_exit) and
                    failure == error.Timeout)
                {
                    self.cancelRequest(request_id, operation) catch {};
                    close_on_error = false;
                    return failure;
                }
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    failure,
                );
            };
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.ExpectedObject,
                ),
            };
            const protocol = objectString(object, "protocol") catch {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.InvalidProtocolEnvelope,
                );
            };
            if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.InvalidProtocolEnvelope,
                );
            }
            const envelope_type = objectString(object, "type") catch {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.InvalidProtocolEnvelope,
                );
            };
            if (!std.mem.eql(u8, envelope_type, "response")) {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.UnexpectedStreamEnvelope,
                );
            }
            const response_id = objectString(object, "id") catch {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.InvalidProtocolEnvelope,
                );
            };
            if (!std.mem.eql(u8, response_id, request_id)) {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    error.UnexpectedResponseId,
                );
            }
            const response = parseExactResponse(object) catch |failure| {
                return self.postDispatchFailure(
                    operation,
                    mutation,
                    failure,
                );
            };
            switch (response) {
                .failure => |failure| {
                    try self.setError(failure);
                    close_on_error = false;
                    return error.RemoteError;
                },
                .success => |result| return .{
                    .owned = message,
                    .value = result,
                },
            }
        }
    }

    fn callClass(
        self: *Client,
        expected: OperationClass,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
    ) !OwnedResult {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        return self.callClassWithDeadline(
            expected,
            operation,
            params,
            mutation,
            &deadline,
        );
    }

    fn callClassWithDeadline(
        self: *Client,
        expected: OperationClass,
        operation: Operation,
        params: raw.wire.Value,
        mutation: ?MutationOptions,
        deadline: *TimeoutDeadline,
    ) !OwnedResult {
        if (operation.class() != expected) return error.WrongOperationClass;
        try self.acquireRequest(deadline);
        defer self.releaseRequest();
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.callLocked(operation, params, mutation, deadline);
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

    fn streamConnection(
        self: *Client,
        deadline: *TimeoutDeadline,
    ) !raw.transport.Connection {
        if (self.isClosed()) return error.ConnectionClosed;
        var connection = if (self.stream_factory) |factory|
            try factory.open(
                self.allocator,
                try deadline.remainingMs(),
            )
        else blk: {
            const path = self.owned_socket_path orelse
                return error.StreamConnectionUnavailable;
            break :blk try raw.transport.connectUnixWithTimeout(
                self.allocator,
                path,
                try deadline.remainingMs(),
            );
        };
        _ = deadline.remainingMs() catch |failure| {
            connection.close();
            connection.deinit();
            return failure;
        };
        return connection;
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
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const connection = try self.streamConnection(&deadline);
        return self.openSessionEventsOn(connection, params, &deadline);
    }

    fn openSessionEventsOn(
        self: *Client,
        connection: raw.transport.Connection,
        params: raw.wire.Value,
        deadline: *TimeoutDeadline,
    ) !SessionEventStream {
        return .{ .raw_stream = try RawStream.open(
            SessionEvent,
            self.allocator,
            connection,
            self.streamOptions(),
            .session_events,
            params,
            deadline,
        ) };
    }

    fn openSessionJournal(
        self: *Client,
        params: raw.wire.Value,
    ) !SessionJournalStream {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const connection = try self.streamConnection(&deadline);
        return .{ .raw_stream = try RawStream.open(
            SessionJournalRecord,
            self.allocator,
            connection,
            self.streamOptions(),
            .session_journal_subscribe,
            params,
            &deadline,
        ) };
    }

    fn openTerminalAttachment(
        self: *Client,
        params: raw.wire.Value,
    ) !TerminalAttachmentStream {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const connection = try self.streamConnection(&deadline);
        return .{ .raw_stream = try RawStream.open(
            TerminalAttachmentItem,
            self.allocator,
            connection,
            self.streamOptions(),
            .terminal_attach,
            params,
            &deadline,
        ) };
    }

    fn openBrowserAttachment(
        self: *Client,
        params: raw.wire.Value,
    ) !BrowserAttachmentStream {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const connection = try self.streamConnection(&deadline);
        return .{ .raw_stream = try RawStream.open(
            BrowserAttachmentItem,
            self.allocator,
            connection,
            self.streamOptions(),
            .browser_attach,
            params,
            &deadline,
        ) };
    }

    fn openSidebarView(
        self: *Client,
        params: raw.wire.Value,
    ) !SidebarViewStream {
        var deadline = try TimeoutDeadline.start(self.timeout_ms);
        const connection = try self.streamConnection(&deadline);
        return .{ .raw_stream = try RawStream.open(
            SidebarViewItem,
            self.allocator,
            connection,
            self.streamOptions(),
            .sidebar_view_attach,
            params,
            &deadline,
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
    value: ResourceEntitySnapshot,
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

pub const ResourceEntitySnapshot = union(ResourceKind) {
    machine: MachineSnapshot,
    session: SessionSnapshot,
    workspace: WorkspaceSnapshot,
    screen: ScreenSnapshot,
    pane: PaneSnapshot,
    tab: TabSnapshot,
    terminal: TerminalSnapshot,
    browser: BrowserSnapshot,
    client: ClientSnapshot,
    notification: NotificationSnapshot,
    agent: AgentSnapshot,
    pairing_request: PairingRequestSnapshot,
    frontend_projection: FrontendProjectionSnapshot,
    sidebar_view: SidebarViewSnapshot,
};

pub const SessionSnapshotEvent = struct {
    cursor: Cursor,
    reset_reason: ?ResetReason,
    snapshot: ResourceSnapshot,
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

pub const RenderCursorStyle = union(enum) {
    block,
    underline,
    bar,
    unknown: []const u8,
};

pub const RenderCursor = struct {
    x: u16,
    y: u16,
    style: RenderCursorStyle,
    blink: bool,
    visible: bool,
    color: ?[]const u8,
};

pub const RenderSnapshot = struct {
    size: Size,
    cursor: RenderCursor,
    default_fg: []const u8,
    default_bg: []const u8,
    scrollback_rows: u32,
    rows: []const RenderRow,
};

pub const RenderPatch = struct {
    cursor: RenderCursor,
    full_reset: bool,
    size: ?Size,
    default_fg: ?[]const u8,
    default_bg: ?[]const u8,
    scrollback_rows: ?u32,
    rows: []const RenderRow,
};

pub const RenderScroll = struct {
    offset: u64,
    at_bottom: bool,
};

pub const TerminalAttachmentItem = union(enum) {
    snapshot: struct {
        terminal_id: TerminalId,
        render: RenderSnapshot,
    },
    patch: struct {
        terminal_id: TerminalId,
        render: RenderPatch,
    },
    scroll: struct {
        terminal_id: TerminalId,
        scroll: RenderScroll,
    },
    unknown: UnknownDiscriminated,
};

pub const BrowserFrameMime = union(enum) {
    png,
    jpeg,
    unknown: []const u8,

    pub fn wireName(self: BrowserFrameMime) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .unknown => |value| value,
        };
    }
};

pub const BrowserAttachmentItem = union(enum) {
    snapshot: struct {
        browser: BrowserSnapshot,
        size: PixelSize,
    },
    frame: struct {
        mime_type: BrowserFrameMime,
        data_base64: []const u8,
        data: []const u8,
        width_px: u32,
        height_px: u32,
        pointer_frame_seq: ?u64,
    },
    state: struct {
        url: []const u8,
        title: []const u8,
        loading: bool,
    },
    unknown: UnknownDiscriminated,
};

pub const SidebarViewItem = union(enum) {
    snapshot: struct {
        sidebar_view: SidebarViewSnapshot,
        render: RenderSnapshot,
    },
    patch: struct {
        sidebar_view_id: SidebarViewId,
        render: RenderPatch,
    },
    scroll: struct {
        sidebar_view_id: SidebarViewId,
        scroll: RenderScroll,
    },
    unknown: UnknownDiscriminated,
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

fn validateExactResourceError(value: raw.wire.Value) !void {
    const object = switch (value) {
        .object => |item| item,
        else => return error.ExpectedObject,
    };
    try ensureOnlyFields(object, &.{
        "code",
        "message",
        "details",
        "retryable",
    });
    _ = try objectString(object, "code");
    _ = try objectString(object, "message");
    _ = object.get("details") orelse return error.MissingField;
    _ = try objectBool(object, "retryable");
}

const ExactResponse = union(enum) {
    success: raw.wire.Value,
    failure: raw.wire.Value,
};

fn parseExactResponse(object: raw.wire.Object) !ExactResponse {
    try ensureOnlyFields(object, &.{
        "protocol",
        "type",
        "id",
        "ok",
        "result",
        "error",
    });
    const protocol = try objectString(object, "protocol");
    if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
        return error.InvalidProtocolEnvelope;
    }
    const envelope_type = try objectString(object, "type");
    if (!std.mem.eql(u8, envelope_type, "response")) {
        return error.UnexpectedStreamEnvelope;
    }
    _ = try objectString(object, "id");
    const ok = switch (object.get("ok") orelse
        return error.MissingResponseStatus) {
        .bool => |item| item,
        else => return error.InvalidResponseStatus,
    };
    if (ok) {
        if (object.get("error") != null) return error.UnexpectedField;
        return .{
            .success = object.get("result") orelse
                return error.MissingResponseResult,
        };
    }
    if (object.get("result") != null) return error.UnexpectedField;
    const failure = object.get("error") orelse
        return error.InvalidResourceError;
    try validateExactResourceError(failure);
    return .{ .failure = failure };
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
    };
}

fn decodeResourceEntitySnapshot(
    allocator: std.mem.Allocator,
    resource: ResourceKind,
    value: raw.wire.Value,
) !ResourceEntitySnapshot {
    return switch (resource) {
        .machine => .{ .machine = try decodeMachineSnapshot(value) },
        .session => .{ .session = try decodeSessionSnapshot(value) },
        .workspace => .{
            .workspace = try decodeWorkspaceSnapshot(value),
        },
        .screen => .{
            .screen = try decodeScreenSnapshot(allocator, value),
        },
        .pane => .{ .pane = try decodePaneSnapshot(value) },
        .tab => .{ .tab = try decodeTabSnapshot(value) },
        .terminal => .{
            .terminal = try decodeTerminalSnapshot(allocator, value),
        },
        .browser => .{ .browser = try decodeBrowserSnapshot(value) },
        .client => .{
            .client = try decodeClientSnapshot(allocator, value),
        },
        .notification => .{
            .notification = try decodeNotificationSnapshot(value),
        },
        .agent => .{ .agent = try decodeAgentSnapshot(value) },
        .pairing_request => .{
            .pairing_request = try decodePairingRequestSnapshot(value),
        },
        .frontend_projection => .{
            .frontend_projection = try decodeFrontendProjectionSnapshot(value),
        },
        .sidebar_view => .{
            .sidebar_view = try decodeSidebarViewSnapshot(value),
        },
    };
}

fn decodeResourceChange(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ResourceChange {
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
    const sequence = try objectUnsigned(u32, object, "sequence", 0);
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
        .value = try decodeResourceEntitySnapshot(
            allocator,
            resource,
            snapshot,
        ),
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
        const snapshot = try decodeResourceSnapshot(
            allocator,
            object.get("snapshot") orelse return error.MissingField,
        );
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
            changes[index] = try decodeResourceChange(
                allocator,
                change,
            );
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

fn journalBoundedString(
    object: raw.wire.Object,
    name: []const u8,
    maximum: usize,
) ![]const u8 {
    const value = try objectString(object, name);
    if (value.len == 0 or value.len > maximum) {
        return error.InvalidJournalString;
    }
    return value;
}

fn journalNullableString(
    object: raw.wire.Object,
    name: []const u8,
) !?[]const u8 {
    return switch (object.get(name) orelse return error.MissingField) {
        .null => null,
        .string => |value| if (value.len == 0 or value.len > 512)
            error.InvalidJournalString
        else
            value,
        else => error.ExpectedString,
    };
}

fn decodeJournalClass(value: []const u8) !JournalClass {
    if (std.mem.eql(u8, value, "state")) return .state;
    if (std.mem.eql(u8, value, "observation")) return .observation;
    if (std.mem.eql(u8, value, "effect")) return .effect;
    if (std.mem.eql(u8, value, "checkpoint")) return .checkpoint;
    return error.InvalidJournalClass;
}

fn decodeJournalReplayPolicy(value: []const u8) !JournalReplayPolicy {
    if (std.mem.eql(u8, value, "required")) return .required;
    if (std.mem.eql(u8, value, "advisory")) return .advisory;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.InvalidJournalReplayPolicy;
}

fn decodeJournalSensitivity(value: []const u8) !JournalSensitivity {
    if (std.mem.eql(u8, value, "public")) return .public;
    if (std.mem.eql(u8, value, "metadata")) return .metadata;
    if (std.mem.eql(u8, value, "sensitive")) return .sensitive;
    if (std.mem.eql(u8, value, "secret")) return .secret;
    return error.InvalidJournalSensitivity;
}

fn decodeJournalProducer(value: raw.wire.Value) !JournalProducer {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "kind", "id" });
    return .{
        .kind = try journalBoundedString(object, "kind", 128),
        .id = try journalBoundedString(object, "id", 512),
    };
}

fn decodeJournalAuthority(value: raw.wire.Value) !?JournalAuthority {
    return switch (value) {
        .null => null,
        .object => |object| blk: {
            try ensureOnlyFields(
                object,
                &.{ "principal_id", "lease_id", "generation", "role" },
            );
            break :blk .{
                .principal_id = try journalBoundedString(
                    object,
                    "principal_id",
                    512,
                ),
                .lease_id = try journalBoundedString(
                    object,
                    "lease_id",
                    512,
                ),
                .generation = try journalBoundedString(
                    object,
                    "generation",
                    128,
                ),
                .role = try journalBoundedString(object, "role", 128),
            };
        },
        else => error.ExpectedObject,
    };
}

fn decodeSessionJournalRecord(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
    envelope_cursor: ?Cursor,
) !SessionJournalRecord {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{
        "sequence",
        "event_id",
        "schema_version",
        "kind",
        "class",
        "replay",
        "occurred_at_ms",
        "committed_at_ms",
        "producer",
        "authority",
        "causation_id",
        "correlation_id",
        "causation_depth",
        "subjects",
        "sensitivity",
        "payload",
        "resource_revision",
        "previous_resource_revision",
    });
    const sequence = try decimalU64(
        object.get("sequence") orelse return error.MissingField,
    );
    const cursor = envelope_cursor orelse return error.MissingStreamCursor;
    if (cursor.revision != sequence) return error.StreamCursorMismatch;
    const raw_subjects = switch (object.get("subjects") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    if (raw_subjects.len > 256) return error.TooManyJournalSubjects;
    const subjects = try allocator.alloc(JournalSubject, raw_subjects.len);
    for (raw_subjects, 0..) |raw_subject, index| {
        const subject = try detailObject(raw_subject);
        try ensureOnlyFields(subject, &.{ "kind", "id" });
        subjects[index] = .{
            .kind = try journalBoundedString(subject, "kind", 128),
            .id = try journalBoundedString(subject, "id", 512),
        };
    }
    return .{
        .sequence = sequence,
        .event_id = try journalBoundedString(object, "event_id", 512),
        .schema_version = try objectUnsigned(
            u32,
            object,
            "schema_version",
            1,
        ),
        .kind = try journalBoundedString(object, "kind", 128),
        .journal_class = try decodeJournalClass(
            try objectString(object, "class"),
        ),
        .replay = try decodeJournalReplayPolicy(
            try objectString(object, "replay"),
        ),
        .occurred_at_ms = try decimalU64(
            object.get("occurred_at_ms") orelse return error.MissingField,
        ),
        .committed_at_ms = try decimalU64(
            object.get("committed_at_ms") orelse return error.MissingField,
        ),
        .producer = try decodeJournalProducer(
            object.get("producer") orelse return error.MissingField,
        ),
        .authority = try decodeJournalAuthority(
            object.get("authority") orelse return error.MissingField,
        ),
        .causation_id = try journalNullableString(object, "causation_id"),
        .correlation_id = try journalNullableString(
            object,
            "correlation_id",
        ),
        .causation_depth = try objectUnsigned(
            u16,
            object,
            "causation_depth",
            0,
        ),
        .subjects = subjects,
        .sensitivity = try decodeJournalSensitivity(
            try objectString(object, "sensitivity"),
        ),
        .payload = object.get("payload") orelse return error.MissingField,
        .resource_revision = try requiredNullableDecimalU64(
            object,
            "resource_revision",
        ),
        .previous_resource_revision = try requiredNullableDecimalU64(
            object,
            "previous_resource_revision",
        ),
    };
}

fn decodeRenderCursorStyle(value: []const u8) RenderCursorStyle {
    if (std.mem.eql(u8, value, "block")) return .block;
    if (std.mem.eql(u8, value, "underline")) return .underline;
    if (std.mem.eql(u8, value, "bar")) return .bar;
    return .{ .unknown = value };
}

fn validateColorHex(value: []const u8) ![]const u8 {
    if (value.len != 7 or value[0] != '#') {
        return error.InvalidColorHex;
    }
    for (value[1..]) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidColorHex;
    }
    return value;
}

fn decodeNullableColor(value: raw.wire.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |text| try validateColorHex(text),
        else => error.ExpectedString,
    };
}

fn decodeRenderCursor(value: raw.wire.Value) !RenderCursor {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "x", "y", "style", "blink", "visible", "color" },
    );
    return .{
        .x = try objectUnsigned(u16, object, "x", 0),
        .y = try objectUnsigned(u16, object, "y", 0),
        .style = decodeRenderCursorStyle(
            try objectString(object, "style"),
        ),
        .blink = try objectBool(object, "blink"),
        .visible = try objectBool(object, "visible"),
        .color = try decodeNullableColor(
            object.get("color") orelse return error.MissingField,
        ),
    };
}

fn decodeRenderRows(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) ![]const RenderRow {
    const raw_rows = switch (value) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const rows = try allocator.alloc(RenderRow, raw_rows.len);
    for (raw_rows, 0..) |row, index| {
        rows[index] = try decodeRenderRow(allocator, row);
    }
    return rows;
}

fn decodeRenderSnapshot(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !RenderSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "size",
            "cursor",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        },
    );
    const size = try decodeSize(
        object.get("size") orelse return error.MissingField,
    );
    const rows = try decodeRenderRows(
        allocator,
        object.get("rows") orelse return error.MissingField,
    );
    if (rows.len != size.rows) return error.InvalidRenderRowCount;
    return .{
        .size = size,
        .cursor = try decodeRenderCursor(
            object.get("cursor") orelse return error.MissingField,
        ),
        .default_fg = try validateColorHex(
            try objectString(object, "default_fg"),
        ),
        .default_bg = try validateColorHex(
            try objectString(object, "default_bg"),
        ),
        .scrollback_rows = try objectUnsigned(
            u32,
            object,
            "scrollback_rows",
            0,
        ),
        .rows = rows,
    };
}

fn decodeRenderPatch(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !RenderPatch {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "cursor",
            "full_reset",
            "size",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        },
    );
    const size = if (object.get("size")) |item|
        try decodeSize(item)
    else
        null;
    const full_reset = try objectBool(object, "full_reset");
    const rows = try decodeRenderRows(
        allocator,
        object.get("rows") orelse return error.MissingField,
    );
    if (size != null and (!full_reset or rows.len != size.?.rows)) {
        return error.InvalidRenderResizePatch;
    }
    return .{
        .cursor = try decodeRenderCursor(
            object.get("cursor") orelse return error.MissingField,
        ),
        .full_reset = full_reset,
        .size = size,
        .default_fg = if (object.get("default_fg")) |item|
            switch (item) {
                .string => |text| try validateColorHex(text),
                else => return error.ExpectedString,
            }
        else
            null,
        .default_bg = if (object.get("default_bg")) |item|
            switch (item) {
                .string => |text| try validateColorHex(text),
                else => return error.ExpectedString,
            }
        else
            null,
        .scrollback_rows = try optionalUnsigned(
            u32,
            object,
            "scrollback_rows",
            0,
        ),
        .rows = rows,
    };
}

fn decodeRenderScroll(value: raw.wire.Value) !RenderScroll {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "offset", "at_bottom" });
    return .{
        .offset = try decimalU64(
            object.get("offset") orelse return error.MissingField,
        ),
        .at_bottom = try objectBool(object, "at_bottom"),
    };
}

fn decodeTerminalAttachmentItem(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !TerminalAttachmentItem {
    const object = try detailObject(value);
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "snapshot")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "terminal_id", "render" },
        );
        return .{ .snapshot = .{
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
            .render = try decodeRenderSnapshot(
                allocator,
                object.get("render") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "patch")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "terminal_id", "render" },
        );
        return .{ .patch = .{
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
            .render = try decodeRenderPatch(
                allocator,
                object.get("render") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "scroll")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "terminal_id", "scroll" },
        );
        return .{ .scroll = .{
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
            .scroll = try decodeRenderScroll(
                object.get("scroll") orelse return error.MissingField,
            ),
        } };
    }
    return .{ .unknown = .{
        .discriminator = kind,
        .raw_object = value,
    } };
}

fn parseBrowserFrameMime(value: []const u8) !BrowserFrameMime {
    if (std.mem.eql(u8, value, "image/png")) return .png;
    if (std.mem.eql(u8, value, "image/jpeg")) return .jpeg;
    return error.InvalidBrowserFrameMime;
}

fn decodeBrowserAttachmentItem(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !BrowserAttachmentItem {
    const object = try detailObject(value);
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "snapshot")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "browser", "size" },
        );
        return .{ .snapshot = .{
            .browser = try decodeBrowserSnapshot(
                object.get("browser") orelse return error.MissingField,
            ),
            .size = try decodePixelSize(
                object.get("size") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "frame")) {
        try ensureOnlyFields(
            object,
            &.{
                "kind",
                "mime_type",
                "data_base64",
                "width_px",
                "height_px",
                "pointer_frame_seq",
            },
        );
        const encoded = try objectString(object, "data_base64");
        return .{ .frame = .{
            .mime_type = try parseBrowserFrameMime(
                try objectString(object, "mime_type"),
            ),
            .data_base64 = encoded,
            .data = try raw.decodeBase64Alloc(allocator, encoded),
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
            .pointer_frame_seq = try requiredNullableDecimalU64(
                object,
                "pointer_frame_seq",
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "state")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "url", "title", "loading" },
        );
        return .{ .state = .{
            .url = try objectString(object, "url"),
            .title = try objectString(object, "title"),
            .loading = try objectBool(object, "loading"),
        } };
    }
    return .{ .unknown = .{
        .discriminator = kind,
        .raw_object = value,
    } };
}

fn decodeSidebarViewItem(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !SidebarViewItem {
    const object = try detailObject(value);
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "snapshot")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "sidebar_view", "render" },
        );
        return .{ .snapshot = .{
            .sidebar_view = try decodeSidebarViewSnapshot(
                object.get("sidebar_view") orelse
                    return error.MissingField,
            ),
            .render = try decodeRenderSnapshot(
                allocator,
                object.get("render") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "patch")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "sidebar_view_id", "render" },
        );
        return .{ .patch = .{
            .sidebar_view_id = try parseRequiredId(
                SidebarViewId,
                object,
                "sidebar_view_id",
            ),
            .render = try decodeRenderPatch(
                allocator,
                object.get("render") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, kind, "scroll")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "sidebar_view_id", "scroll" },
        );
        return .{ .scroll = .{
            .sidebar_view_id = try parseRequiredId(
                SidebarViewId,
                object,
                "sidebar_view_id",
            ),
            .scroll = try decodeRenderScroll(
                object.get("scroll") orelse return error.MissingField,
            ),
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
    if (comptime Item == SessionJournalRecord) {
        return decodeSessionJournalRecord(allocator, value, cursor);
    }
    if (comptime Item == TerminalAttachmentItem) {
        return decodeTerminalAttachmentItem(allocator, value);
    }
    if (comptime Item == BrowserAttachmentItem) {
        return decodeBrowserAttachmentItem(allocator, value);
    }
    if (comptime Item == SidebarViewItem) {
        return decodeSidebarViewItem(allocator, value);
    }
    @compileError("unsupported resource stream item");
}

const DomainItemValidator = *const fn (
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
    cursor: ?Cursor,
) anyerror!void;

fn domainItemValidator(comptime Item: type) DomainItemValidator {
    return struct {
        fn validate(
            allocator: std.mem.Allocator,
            value: raw.wire.Value,
            cursor: ?Cursor,
        ) !void {
            _ = try domainItem(Item, allocator, value, cursor);
        }
    }.validate;
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

const AttachmentSelector = union(enum) {
    none,
    terminal: []u8,
    browser: []u8,
};

const RawStream = struct {
    pub const max_buffered_items: usize = 256;
    pub const max_buffered_bytes: usize = 16 * 1024 * 1024;

    const ParsedItemEnvelope = struct {
        sequence: u64,
        cursor: ?Cursor,
        item: raw.wire.Value,
    };

    client: Client,
    stream_id: StreamId,
    machine_selector: []u8,
    session_selector: []u8,
    attachment: AttachmentSelector = .none,
    attachment_lease: ?[]u8 = null,
    pending: std.ArrayList(raw.wire.OwnedValue) = .empty,
    pending_sizes: std.ArrayList(usize) = .empty,
    pending_bytes: usize = 0,
    end_frame: ?raw.wire.OwnedValue = null,
    end_error: ?OwnedResourceError = null,
    local_end_generation: ?[]u8 = null,
    stream_end: ?StreamEnd = null,
    item_validator: DomainItemValidator,
    cleanup_started: bool = false,
    cleanup_finished: bool = false,
    cancel_failure: ?anyerror = null,
    deinitialized: bool = false,

    fn open(
        comptime Item: type,
        allocator: std.mem.Allocator,
        connection: raw.transport.Connection,
        options: Options,
        operation: Operation,
        params: raw.wire.Value,
        deadline: *TimeoutDeadline,
    ) !RawStream {
        var stream_client = Client.init(allocator, connection, options);
        var stream_client_owned = true;
        errdefer if (stream_client_owned) stream_client.deinit();
        if (operation.class() != .stream_open) {
            return error.WrongOperationClass;
        }
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
        var owned_machine_owned = true;
        errdefer if (owned_machine_owned) allocator.free(owned_machine);
        const owned_session = try allocator.dupe(u8, session_selector);
        var owned_session_owned = true;
        errdefer if (owned_session_owned) allocator.free(owned_session);
        const attachment: AttachmentSelector = switch (operation) {
            .terminal_attach => blk: {
                const selector = try objectString(object, "terminal");
                break :blk .{
                    .terminal = try allocator.dupe(u8, selector),
                };
            },
            .browser_attach => blk: {
                const selector = try objectString(object, "browser");
                break :blk .{
                    .browser = try allocator.dupe(u8, selector),
                };
            },
            else => .none,
        };
        var attachment_owned = true;
        errdefer if (attachment_owned) {
            switch (attachment) {
                .terminal => |selector| allocator.free(selector),
                .browser => |selector| allocator.free(selector),
                .none => {},
            }
        };
        var stream = RawStream{
            .client = stream_client,
            .stream_id = id,
            .machine_selector = owned_machine,
            .session_selector = owned_session,
            .attachment = attachment,
            .item_validator = domainItemValidator(Item),
        };
        stream_client_owned = false;
        owned_machine_owned = false;
        owned_session_owned = false;
        attachment_owned = false;
        errdefer stream.deinit();
        try stream.openWithDeadline(
            operation,
            .{ .object = object },
            deadline,
        );
        return stream;
    }

    fn validateOpenResult(
        self: *RawStream,
        value: raw.wire.Value,
    ) !void {
        const open_result = switch (value) {
            .object => |item| item,
            else => return error.ExpectedObject,
        };
        const view_attachment = switch (self.attachment) {
            .terminal, .browser => true,
            .none => false,
        };
        if (view_attachment) {
            try ensureOnlyFields(
                open_result,
                &.{ "stream_id", "attachment_lease" },
            );
        } else {
            try ensureOnlyFields(open_result, &.{ "stream_id", "cursor" });
        }
        const acknowledged_stream_id = try objectString(
            open_result,
            "stream_id",
        );
        if (!std.mem.eql(
            u8,
            acknowledged_stream_id,
            self.stream_id.slice(),
        )) {
            return error.StreamIdMismatch;
        }
        if (view_attachment) {
            const lease = try objectString(open_result, "attachment_lease");
            if (lease.len < 1 or lease.len > 128) {
                return error.InvalidAttachmentLease;
            }
            self.attachment_lease = try self.client.allocator.dupe(u8, lease);
        } else if (open_result.get("cursor")) |cursor| {
            _ = try parseStrictCursor(cursor);
        }
    }

    fn openWithDeadline(
        self: *RawStream,
        operation: Operation,
        params: raw.wire.Value,
        deadline: *TimeoutDeadline,
    ) !void {
        try self.client.acquireRequest(deadline);
        defer self.client.releaseRequest();
        self.client.mutex.lock();
        defer self.client.mutex.unlock();
        self.client.clearError();
        self.client.clearMutationTransportUncertain();
        const request_id = try self.client.requestId();
        defer self.client.allocator.free(request_id);
        errdefer self.client.close();
        try self.client.sendRequestWithDeadline(
            request_id,
            operation,
            params,
            null,
            deadline,
            null,
        );
        while (true) {
            var message = try self.client.readMessageWithDeadline(deadline);
            var message_owned = true;
            defer if (message_owned) message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const protocol = objectString(object, "protocol") catch
                return error.InvalidProtocolEnvelope;
            if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
                return error.InvalidProtocolEnvelope;
            }
            const envelope_type = objectString(object, "type") catch
                return error.InvalidProtocolEnvelope;
            if (std.mem.eql(u8, envelope_type, "response")) {
                const response_id = objectString(object, "id") catch
                    return error.InvalidProtocolEnvelope;
                if (!std.mem.eql(u8, response_id, request_id)) {
                    return error.UnexpectedResponseId;
                }
                switch (try parseExactResponse(object)) {
                    .failure => |failure| {
                        try self.client.setError(failure);
                        return error.RemoteError;
                    },
                    .success => |result| {
                        try self.validateOpenResult(result);
                        return;
                    },
                }
            }
            if (std.mem.eql(u8, envelope_type, "stream_item")) {
                if (self.stream_end != null) {
                    return error.UnexpectedStreamEnvelope;
                }
                const envelope = try self.parseItemEnvelope(object);
                try self.validateItemDomain(envelope);
                message_owned = false;
                try self.queuePending(message);
                continue;
            }
            if (std.mem.eql(u8, envelope_type, "stream_end")) {
                if (self.stream_end != null) {
                    return error.DuplicateStreamEnd;
                }
                try self.storeEnd(message, null);
                message_owned = false;
                continue;
            }
            return error.UnexpectedStreamEnvelope;
        }
    }

    fn deinit(self: *RawStream) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        self.client.close();
        for (self.pending.items) |*message| message.deinit();
        self.pending.deinit(self.client.allocator);
        self.pending_sizes.deinit(self.client.allocator);
        if (self.end_frame) |*frame| frame.deinit();
        if (self.end_error) |*failure| failure.deinit();
        if (self.local_end_generation) |generation| {
            self.client.allocator.free(generation);
        }
        self.client.allocator.free(self.machine_selector);
        self.client.allocator.free(self.session_selector);
        switch (self.attachment) {
            .terminal => |selector| self.client.allocator.free(selector),
            .browser => |selector| self.client.allocator.free(selector),
            .none => {},
        }
        if (self.attachment_lease) |lease| {
            self.client.allocator.free(lease);
        }
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

    fn parseItemEnvelope(
        self: *const RawStream,
        object: raw.wire.Object,
    ) !ParsedItemEnvelope {
        try ensureOnlyFields(object, &.{
            "protocol",
            "type",
            "stream_id",
            "sequence",
            "cursor",
            "item",
        });
        const protocol = try objectString(object, "protocol");
        if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
            return error.InvalidProtocolEnvelope;
        }
        const envelope_type = try objectString(object, "type");
        if (!std.mem.eql(u8, envelope_type, "stream_item")) {
            return error.UnexpectedStreamEnvelope;
        }
        const encoded_stream_id = try objectString(object, "stream_id");
        if (!std.mem.eql(
            u8,
            encoded_stream_id,
            self.stream_id.slice(),
        )) {
            return error.StreamIdMismatch;
        }
        return .{
            .sequence = try decimalU64(
                object.get("sequence") orelse return error.MissingField,
            ),
            .cursor = if (object.get("cursor")) |cursor|
                try parseStrictCursor(cursor)
            else
                null,
            .item = object.get("item") orelse return error.MissingField,
        };
    }

    fn validateItemDomain(
        self: *const RawStream,
        envelope: ParsedItemEnvelope,
    ) !void {
        var decoded = std.heap.ArenaAllocator.init(self.client.allocator);
        defer decoded.deinit();
        try self.item_validator(
            decoded.allocator(),
            envelope.item,
            envelope.cursor,
        );
    }

    fn storeEnd(
        self: *RawStream,
        message: raw.wire.OwnedValue,
        expected_reason: ?StreamEndReason,
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
        try ensureOnlyFields(object, &.{
            "protocol",
            "type",
            "stream_id",
            "reason",
            "cursor",
            "error",
            "recovery",
        });
        const protocol = try objectString(object, "protocol");
        if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
            return error.InvalidProtocolEnvelope;
        }
        const envelope_type = try objectString(object, "type");
        if (!std.mem.eql(u8, envelope_type, "stream_end")) {
            return error.UnexpectedStreamEnvelope;
        }
        const encoded_stream_id = try objectString(object, "stream_id");
        if (!std.mem.eql(
            u8,
            encoded_stream_id,
            self.stream_id.slice(),
        )) {
            return error.StreamIdMismatch;
        }
        const reason = try parseStreamEndReason(
            try objectString(object, "reason"),
        );
        if (expected_reason) |expected| {
            if (reason != expected) return error.UnexpectedStreamEndReason;
        }
        const error_value = object.get("error");
        if ((reason == .@"error") != (error_value != null)) {
            return error.InvalidStreamEndErrorPresence;
        }
        const cursor = if (object.get("cursor")) |cursor_value|
            try parseStrictCursor(cursor_value)
        else
            null;
        const recovery = if (object.get("recovery")) |recovery_value|
            switch (recovery_value) {
                .string => |item| item,
                else => return error.ExpectedString,
            }
        else
            null;
        if (error_value) |embedded_error| {
            try validateExactResourceError(embedded_error);
            self.end_error = try ownedErrorFromValue(
                self.client.allocator,
                embedded_error,
            );
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
        if (self.pending.items.len == 0 and self.stream_end != null) {
            return null;
        }
        errdefer self.client.close();
        while (true) {
            var message = if (self.pending.items.len > 0) blk: {
                const pending_size = self.pending_sizes.orderedRemove(0);
                self.pending_bytes -= pending_size;
                break :blk self.pending.orderedRemove(0);
            } else try self.client.readMessageWithTimeout(null);
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const envelope_type = try objectString(object, "type");
            if (std.mem.eql(u8, envelope_type, "stream_end")) {
                try self.storeEnd(message, null);
                return null;
            }
            if (std.mem.eql(u8, envelope_type, "stream_item")) {
                _ = try self.parseItemEnvelope(object);
                return message;
            }
            if (!self.envelopeForThisStream(object)) {
                message.deinit();
                continue;
            }
            return error.UnexpectedStreamEnvelope;
        }
    }

    /// Takes ownership of `message` on entry. Success stores it in `pending`;
    /// every error path deinitializes it before returning.
    fn queuePending(
        self: *RawStream,
        message: raw.wire.OwnedValue,
    ) !void {
        var appended = false;
        errdefer {
            if (appended) _ = self.pending.pop();
            var discarded = message;
            discarded.deinit();
        }
        if (self.pending.items.len >= max_buffered_items) {
            try self.storeLocalOverflow(message.value);
            return error.StreamBufferFull;
        }
        const encoded = try raw.wire.stringifyAlloc(
            self.client.allocator,
            message.value,
        );
        defer self.client.allocator.free(encoded);
        if (encoded.len > max_buffered_bytes or
            self.pending_bytes > max_buffered_bytes - encoded.len)
        {
            try self.storeLocalOverflow(message.value);
            return error.StreamBufferFull;
        }
        try self.pending.append(self.client.allocator, message);
        appended = true;
        try self.pending_sizes.append(
            self.client.allocator,
            encoded.len,
        );
        self.pending_bytes += encoded.len;
    }

    fn storeLocalOverflow(
        self: *RawStream,
        envelope: raw.wire.Value,
    ) !void {
        if (self.stream_end != null) return;
        if (self.cleanup_started) {
            self.client.close();
            return;
        }
        self.cleanup_started = true;
        errdefer self.client.close();
        const object = switch (envelope) {
            .object => |item| item,
            else => return error.ExpectedObject,
        };
        const cursor = if (object.get("cursor")) |cursor_value| blk: {
            const parsed = try parseStrictCursor(cursor_value);
            const generation = try self.client.allocator.dupe(
                u8,
                parsed.generation,
            );
            self.local_end_generation = generation;
            break :blk Cursor{
                .generation = generation,
                .revision = parsed.revision,
            };
        } else null;
        self.stream_end = .{
            .reason = .gap,
            .cursor = cursor,
            .recovery = "sdk.buffer_overflow",
            .resource_error = null,
        };
        // Every public stream owns a dedicated connection, so this cannot
        // interrupt the control client or a sibling stream.
        self.client.close();
        self.cleanup_finished = true;
    }

    fn control(
        self: *RawStream,
        operation: Operation,
        params: raw.wire.Value,
    ) !OwnedResult {
        if (operation.class() != .connection_control) {
            return error.WrongOperationClass;
        }
        var deadline = try TimeoutDeadline.start(self.client.timeout_ms);
        try self.client.acquireRequest(&deadline);
        defer self.client.releaseRequest();
        self.client.mutex.lock();
        defer self.client.mutex.unlock();
        self.client.clearError();
        const request_id = try self.client.requestId();
        defer self.client.allocator.free(request_id);
        try self.client.sendRequestWithDeadline(
            request_id,
            operation,
            params,
            null,
            &deadline,
            null,
        );
        var close_on_error = true;
        errdefer if (close_on_error) self.client.close();
        while (true) {
            var message = try self.client.readMessageWithDeadline(&deadline);
            var message_owned = true;
            errdefer if (message_owned) message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const envelope_type = try objectString(object, "type");
            if (std.mem.eql(u8, envelope_type, "response")) {
                const id = objectString(object, "id") catch {
                    return error.InvalidProtocolEnvelope;
                };
                if (!std.mem.eql(u8, id, request_id)) {
                    return error.UnexpectedResponseId;
                }
                switch (try parseExactResponse(object)) {
                    .failure => |failure| {
                        try self.client.setError(failure);
                        close_on_error = false;
                        return error.RemoteError;
                    },
                    .success => |result| return .{
                        .owned = message,
                        .value = result,
                    },
                }
            }
            if (std.mem.eql(u8, envelope_type, "stream_item")) {
                _ = try self.parseItemEnvelope(object);
                message_owned = false;
                try self.queuePending(message);
                continue;
            }
            if (std.mem.eql(u8, envelope_type, "stream_end")) {
                try self.storeEnd(message, null);
                continue;
            }
            if (!self.envelopeForThisStream(object)) {
                message.deinit();
                continue;
            }
            return error.UnexpectedStreamEnvelope;
        }
    }

    fn cancel(self: *RawStream) !*const StreamEnd {
        if (self.cleanup_started) {
            if (self.cleanup_finished) {
                if (self.stream_end) |_| return &self.stream_end.?;
            }
            if (self.cancel_failure) |failure| return failure;
            return error.ConnectionClosed;
        }
        if (self.stream_end) |_| return &self.stream_end.?;
        self.cleanup_started = true;
        errdefer |failure| {
            self.cancel_failure = failure;
            self.client.close();
        }
        var deadline = try TimeoutDeadline.start(self.client.timeout_ms);
        try self.client.acquireRequest(&deadline);
        defer self.client.releaseRequest();
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
        try self.client.sendRequestWithDeadline(
            request_id,
            .stream_cancel,
            .{ .object = params },
            null,
            &deadline,
            null,
        );
        var response_seen = false;
        while (!response_seen or self.stream_end == null) {
            _ = try deadline.remainingMs();
            var message = if (self.pending.items.len > 0) blk: {
                const pending_size = self.pending_sizes.orderedRemove(0);
                self.pending_bytes -= pending_size;
                break :blk self.pending.orderedRemove(0);
            } else try self.client.readMessageWithDeadline(&deadline);
            errdefer message.deinit();
            const object = switch (message.value) {
                .object => |item| item,
                else => return error.ExpectedObject,
            };
            const protocol = objectString(object, "protocol") catch
                return error.InvalidProtocolEnvelope;
            if (!std.mem.eql(u8, protocol, "cmux.protocol/2")) {
                return error.InvalidProtocolEnvelope;
            }
            const envelope_type = objectString(object, "type") catch
                return error.InvalidProtocolEnvelope;
            if (std.mem.eql(u8, envelope_type, "response")) {
                if (response_seen) return error.DuplicateCancelResponse;
                const id = objectString(object, "id") catch
                    return error.InvalidProtocolEnvelope;
                if (!std.mem.eql(u8, id, request_id)) {
                    message.deinit();
                    continue;
                }
                const result = switch (try parseExactResponse(object)) {
                    .failure => |failure| {
                        try self.client.setError(failure);
                        return error.RemoteError;
                    },
                    .success => |success| switch (success) {
                        .object => |item| item,
                        else => return error.ExpectedObject,
                    },
                };
                if (result.count() != 0) return error.UnexpectedField;
                response_seen = true;
                message.deinit();
                continue;
            }
            if (std.mem.eql(u8, envelope_type, "stream_end")) {
                if (self.stream_end != null) return error.DuplicateStreamEnd;
                try self.storeEnd(message, .canceled);
                continue;
            }
            if (std.mem.eql(u8, envelope_type, "stream_item")) {
                if (self.stream_end != null) {
                    return error.UnexpectedStreamEnvelope;
                }
                const envelope = try self.parseItemEnvelope(object);
                try self.validateItemDomain(envelope);
                // Items already queued before cancellation are discarded.
                message.deinit();
                continue;
            }
            return error.UnexpectedStreamEnvelope;
        }
        _ = try deadline.remainingMs();
        self.client.close();
        self.cleanup_finished = true;
        return &self.stream_end.?;
    }
};

fn nextTypedStreamItem(
    comptime Item: type,
    raw_stream: *RawStream,
) !?OwnedStreamItem(Item) {
    errdefer raw_stream.client.close();
    var message = (try raw_stream.nextRaw()) orelse return null;
    errdefer message.deinit();
    var decoded = std.heap.ArenaAllocator.init(
        raw_stream.client.allocator,
    );
    errdefer decoded.deinit();
    const object = switch (message.value) {
        .object => |value| value,
        else => return error.ExpectedObject,
    };
    const envelope = try raw_stream.parseItemEnvelope(object);
    const value = try domainItem(
        Item,
        decoded.allocator(),
        envelope.item,
        envelope.cursor,
    );
    return .{
        .owned = message,
        .decoded = decoded,
        .sequence = envelope.sequence,
        .cursor = envelope.cursor,
        .value = value,
    };
}

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
            return nextTypedStreamItem(Item, &self.raw_stream);
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
pub const SessionJournalStream = TypedStream(SessionJournalRecord);
pub const SidebarViewStream = TypedStream(SidebarViewItem);

pub const TerminalAttachmentStream = struct {
    const Self = @This();
    pub const OwnedItem = OwnedStreamItem(TerminalAttachmentItem);

    raw_stream: RawStream,

    pub fn deinit(self: *Self) void {
        self.raw_stream.deinit();
        self.* = undefined;
    }

    pub fn next(self: *Self) !?OwnedItem {
        return nextTypedStreamItem(
            TerminalAttachmentItem,
            &self.raw_stream,
        );
    }

    pub fn resizeTerminalViewer(
        self: *Self,
        cols: u16,
        rows: u16,
    ) !OwnedViewerResizeResult {
        if (cols == 0 or rows == 0) {
            return error.InvalidTerminalSize;
        }
        var arena = std.heap.ArenaAllocator.init(
            self.raw_stream.client.allocator,
        );
        defer arena.deinit();
        const allocator = arena.allocator();
        var params = raw.wire.Object.init(allocator);
        try params.put(
            "machine",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.machine_selector,
            ) },
        );
        try params.put(
            "session",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.session_selector,
            ) },
        );
        const terminal = switch (self.raw_stream.attachment) {
            .terminal => |selector| selector,
            else => return error.NotTerminalAttachment,
        };
        try params.put(
            "terminal",
            .{ .string = try allocator.dupe(u8, terminal) },
        );
        const lease = self.raw_stream.attachment_lease orelse
            return error.MissingAttachmentLease;
        try params.put(
            "attachment_lease",
            .{ .string = try allocator.dupe(u8, lease) },
        );
        try params.put("cols", .{ .integer = cols });
        try params.put("rows", .{ .integer = rows });
        return decodeOwnedSimpleResult(
            ViewerResizeResult,
            try self.raw_stream.control(
                .terminal_viewer_resize,
                .{ .object = params },
            ),
        );
    }

    pub fn releaseTerminalViewer(
        self: *Self,
    ) !OwnedViewerReleaseResult {
        var arena = std.heap.ArenaAllocator.init(
            self.raw_stream.client.allocator,
        );
        defer arena.deinit();
        const allocator = arena.allocator();
        var params = raw.wire.Object.init(allocator);
        try params.put(
            "machine",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.machine_selector,
            ) },
        );
        try params.put(
            "session",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.session_selector,
            ) },
        );
        const terminal = switch (self.raw_stream.attachment) {
            .terminal => |selector| selector,
            else => return error.NotTerminalAttachment,
        };
        try params.put(
            "terminal",
            .{ .string = try allocator.dupe(u8, terminal) },
        );
        const lease = self.raw_stream.attachment_lease orelse
            return error.MissingAttachmentLease;
        try params.put(
            "attachment_lease",
            .{ .string = try allocator.dupe(u8, lease) },
        );
        return decodeOwnedSimpleResult(
            ViewerReleaseResult,
            try self.raw_stream.control(
                .terminal_viewer_release,
                .{ .object = params },
            ),
        );
    }

    pub fn cancel(self: *Self) !*const StreamEnd {
        return self.raw_stream.cancel();
    }

    pub fn end(self: *const Self) ?StreamEnd {
        return self.raw_stream.stream_end;
    }
};

pub const BrowserAttachmentStream = struct {
    const Self = @This();
    pub const OwnedItem = OwnedStreamItem(BrowserAttachmentItem);

    raw_stream: RawStream,

    pub fn deinit(self: *Self) void {
        self.raw_stream.deinit();
        self.* = undefined;
    }

    pub fn next(self: *Self) !?OwnedItem {
        return nextTypedStreamItem(
            BrowserAttachmentItem,
            &self.raw_stream,
        );
    }

    pub fn resizeBrowserViewer(
        self: *Self,
        width_px: u32,
        height_px: u32,
    ) !OwnedBrowserViewerResizeResult {
        if (width_px == 0 or height_px == 0) {
            return error.InvalidBrowserSize;
        }
        var arena = std.heap.ArenaAllocator.init(
            self.raw_stream.client.allocator,
        );
        defer arena.deinit();
        const allocator = arena.allocator();
        var params = raw.wire.Object.init(allocator);
        try params.put(
            "machine",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.machine_selector,
            ) },
        );
        try params.put(
            "session",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.session_selector,
            ) },
        );
        const browser = switch (self.raw_stream.attachment) {
            .browser => |selector| selector,
            else => return error.NotBrowserAttachment,
        };
        try params.put(
            "browser",
            .{ .string = try allocator.dupe(u8, browser) },
        );
        const lease = self.raw_stream.attachment_lease orelse
            return error.MissingAttachmentLease;
        try params.put(
            "attachment_lease",
            .{ .string = try allocator.dupe(u8, lease) },
        );
        try params.put("width_px", .{ .integer = width_px });
        try params.put("height_px", .{ .integer = height_px });
        return decodeOwnedSimpleResult(
            BrowserViewerResizeResult,
            try self.raw_stream.control(
                .browser_viewer_resize,
                .{ .object = params },
            ),
        );
    }

    pub fn releaseBrowserViewer(
        self: *Self,
    ) !OwnedViewerReleaseResult {
        var arena = std.heap.ArenaAllocator.init(
            self.raw_stream.client.allocator,
        );
        defer arena.deinit();
        const allocator = arena.allocator();
        var params = raw.wire.Object.init(allocator);
        try params.put(
            "machine",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.machine_selector,
            ) },
        );
        try params.put(
            "session",
            .{ .string = try allocator.dupe(
                u8,
                self.raw_stream.session_selector,
            ) },
        );
        const browser = switch (self.raw_stream.attachment) {
            .browser => |selector| selector,
            else => return error.NotBrowserAttachment,
        };
        try params.put(
            "browser",
            .{ .string = try allocator.dupe(u8, browser) },
        );
        const lease = self.raw_stream.attachment_lease orelse
            return error.MissingAttachmentLease;
        try params.put(
            "attachment_lease",
            .{ .string = try allocator.dupe(u8, lease) },
        );
        return decodeOwnedSimpleResult(
            ViewerReleaseResult,
            try self.raw_stream.control(
                .browser_viewer_release,
                .{ .object = params },
            ),
        );
    }

    pub fn cancel(self: *Self) !*const StreamEnd {
        return self.raw_stream.cancel();
    }

    pub fn end(self: *const Self) ?StreamEnd {
        return self.raw_stream.stream_end;
    }
};

pub const RunOptions = struct {
    command: RunCommand,
    cwd: ?[]const u8 = null,
    name: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    correlation_key: ?[]const u8 = null,
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
    correlation_key: ?[]const u8 = null,
};

pub const CreateBrowserTabOptions = struct {
    url: []const u8,
    name: ?[]const u8 = null,
    width_px: ?u32 = null,
    height_px: ?u32 = null,
    correlation_key: ?[]const u8 = null,
};

pub const CreateWorkspaceOptions = struct {
    name: ?[]const u8 = null,
    initial_content: InitialContent = .terminal,
    correlation_key: ?[]const u8 = null,
};

pub const CreateScreenOptions = struct {
    name: ?[]const u8 = null,
    correlation_key: ?[]const u8 = null,
};

pub const UndoLayoutOptions = struct {
    confirm_close: bool = false,
    confirmation_token: ?[]const u8 = null,
};

pub const CreatePaneOptions = struct {
    cwd: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    correlation_key: ?[]const u8 = null,
};

pub const Direction = union(enum) {
    left,
    right,
    up,
    down,
    unknown: []const u8,

    pub fn wireName(self: Direction) []const u8 {
        return switch (self) {
            inline .left, .right, .up, .down => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const SplitOptions = struct {
    direction: Direction,
    ratio: ?f64 = null,
    viewport_width: ?f64 = null,
    cwd: ?[]const u8 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    correlation_key: ?[]const u8 = null,
};

pub const MoveDestination = struct {
    workspace: WorkspaceId,
    screen: ScreenId,
    pane: PaneId,
    index: ?u32 = null,
};

pub const TerminalProjectOptions = struct {
    destination: MoveDestination,
    name: ?[]const u8 = null,
};

pub const TerminalMouseKind = union(enum) {
    press,
    release,
    move,
    wheel,
    unknown: []const u8,

    pub fn wireName(self: TerminalMouseKind) []const u8 {
        return switch (self) {
            inline .press, .release, .move, .wheel => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const BrowserKeyKind = union(enum) {
    press,
    release,
    unknown: []const u8,

    pub fn wireName(self: BrowserKeyKind) []const u8 {
        return switch (self) {
            inline .press, .release => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const BrowserMouseKind = union(enum) {
    move,
    down,
    up,
    unknown: []const u8,

    pub fn wireName(self: BrowserMouseKind) []const u8 {
        return switch (self) {
            inline .move, .down, .up => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const InputModifier = union(enum) {
    shift,
    alt,
    control,
    super,
    unknown: []const u8,

    pub fn wireName(self: InputModifier) []const u8 {
        return switch (self) {
            inline .shift, .alt, .control, .super => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const TerminalMouseOptions = struct {
    kind: TerminalMouseKind,
    button: ?u8 = null,
    row: ?u16 = null,
    column: ?u16 = null,
    delta_rows: ?i32 = null,
    modifiers: []const InputModifier = &.{},
};

pub const BrowserKeyOptions = struct {
    kind: BrowserKeyKind,
    key: []const u8,
    modifiers: []const InputModifier = &.{},
};

pub const BrowserMouseOptions = struct {
    kind: BrowserMouseKind,
    x_px: u32,
    y_px: u32,
    pointer_frame_seq: u64,
    button: ?u8 = null,
    click_count: ?u8 = null,
};

pub const BrowserWheelOptions = struct {
    delta_x: f64,
    delta_y: f64,
    pointer_frame_seq: u64,
    x_px: ?u32 = null,
    y_px: ?u32 = null,
};

pub const TerminalAttachOptions = struct {
    read_only: ?bool = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
};

pub const BrowserAttachOptions = struct {
    width_px: ?u32 = null,
    height_px: ?u32 = null,
};

pub const NotificationListOptions = struct {
    limit: ?u32 = null,
};

pub const NotificationCreateOptions = struct {
    title: []const u8,
    body: []const u8,
    level: NotificationLevel = .info,
    terminal_id: ?TerminalId = null,
};

pub const AgentListOptions = struct {
    terminal_id: ?TerminalId = null,
    state: ?AgentState = null,
};

pub const AgentReportOptions = struct {
    terminal_id: TerminalId,
    state: AgentState,
    source: AgentSource,
    source_session: ?[]const u8 = null,
};

pub const SidebarEnsureOptions = struct {
    cols: u16,
    rows: u16,
    relaunch: bool = false,
};

pub const RendererGrantRequest = struct {
    ttl_ms: ?u32 = null,
};

pub const TerminalDefaultsUpdate = struct {
    foreground: OptionalStringUpdate = .unchanged,
    background: OptionalStringUpdate = .unchanged,
    cursor: OptionalStringUpdate = .unchanged,
    selection_background: OptionalStringUpdate = .unchanged,
    selection_foreground: OptionalStringUpdate = .unchanged,
    cursor_style: OptionalCursorStyleUpdate = .unchanged,
    cursor_blink: OptionalBoolUpdate = .unchanged,
    palette: OptionalPaletteUpdate = .unchanged,
    complete: ?bool = null,
};

pub const OptionalStringUpdate = union(enum) {
    unchanged,
    set: []const u8,
    clear,
};

pub const CursorStyle = union(enum) {
    block,
    bar,
    underline,
    unknown: []const u8,

    pub fn wireName(self: CursorStyle) []const u8 {
        return switch (self) {
            inline .block, .bar, .underline => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const OptionalCursorStyleUpdate = union(enum) {
    unchanged,
    set: CursorStyle,
    clear,
};

pub const OptionalBoolUpdate = union(enum) {
    unchanged,
    set: bool,
    clear,
};

pub const OptionalPaletteUpdate = union(enum) {
    unchanged,
    set: raw.wire.Object,
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

        fn putDecimal(
            self: *Self,
            name: []const u8,
            value: u64,
        ) !void {
            const encoded = try std.fmt.allocPrint(
                self.arena.allocator(),
                "{d}",
                .{value},
            );
            try self.putString(name, encoded);
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

fn encodeSessionJournalOptions(
    comptime Id: type,
    params: *Params(Id),
    options: SessionJournalOptions,
) !void {
    if (options.cursor != null and options.start != null) {
        return error.ConflictingJournalStart;
    }
    const allocator = params.arena.allocator();
    if (options.cursor) |cursor| {
        if (cursor.generation.len == 0 or cursor.generation.len > 128) {
            return error.InvalidCursorGeneration;
        }
        var encoded = raw.wire.Object.init(allocator);
        try encoded.put(
            "generation",
            .{ .string = try allocator.dupe(u8, cursor.generation) },
        );
        try encoded.put(
            "revision",
            .{ .string = try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{cursor.revision},
            ) },
        );
        try params.putValue("cursor", .{ .object = encoded });
    }
    if (options.start) |start| {
        try params.putString("start", start.wireName());
    }
    if (options.follow) |follow| {
        try params.putValue("follow", .{ .bool = follow });
    }

    const filter = options.filter;
    if (filter.kinds.len > 64 or
        filter.classes.len > 4 or
        filter.subjects.len > 64)
    {
        return error.TooManyJournalFilters;
    }
    if (filter.max_sensitivity == .secret) {
        return error.SecretJournalRecordsUnavailable;
    }
    var encoded_filter = raw.wire.Object.init(allocator);
    if (filter.kinds.len > 0) {
        var values = std.json.Array.init(allocator);
        for (filter.kinds) |kind| {
            if (kind.len == 0 or kind.len > 128) {
                return error.InvalidJournalFilter;
            }
            try values.append(.{
                .string = try allocator.dupe(u8, kind),
            });
        }
        try encoded_filter.put("kinds", .{ .array = values });
    }
    if (filter.classes.len > 0) {
        var values = std.json.Array.init(allocator);
        for (filter.classes) |journal_class| {
            try values.append(.{
                .string = try allocator.dupe(
                    u8,
                    journal_class.wireName(),
                ),
            });
        }
        try encoded_filter.put("classes", .{ .array = values });
    }
    if (filter.subjects.len > 0) {
        var values = std.json.Array.init(allocator);
        for (filter.subjects) |subject| {
            if (subject.kind == null and subject.id == null) {
                return error.EmptyJournalSubjectFilter;
            }
            var encoded = raw.wire.Object.init(allocator);
            if (subject.kind) |kind| {
                if (kind.len == 0 or kind.len > 128) {
                    return error.InvalidJournalFilter;
                }
                try encoded.put(
                    "kind",
                    .{ .string = try allocator.dupe(u8, kind) },
                );
            }
            if (subject.id) |id| {
                if (id.len == 0 or id.len > 512) {
                    return error.InvalidJournalFilter;
                }
                try encoded.put(
                    "id",
                    .{ .string = try allocator.dupe(u8, id) },
                );
            }
            try values.append(.{ .object = encoded });
        }
        try encoded_filter.put("subjects", .{ .array = values });
    }
    if (filter.max_sensitivity) |sensitivity| {
        try encoded_filter.put(
            "max_sensitivity",
            .{
                .string = try allocator.dupe(
                    u8,
                    sensitivity.wireName(),
                ),
            },
        );
    }
    if (filter.regex) |regex_filter| {
        if (regex_filter.pattern.len == 0 or regex_filter.pattern.len > 1024) {
            return error.InvalidJournalFilter;
        }
        var encoded = raw.wire.Object.init(allocator);
        try encoded.put(
            try allocator.dupe(u8, "pattern"),
            .{ .string = try allocator.dupe(u8, regex_filter.pattern) },
        );
        try encoded.put(
            try allocator.dupe(u8, "field"),
            .{ .string = try allocator.dupe(u8, @tagName(regex_filter.field)) },
        );
        try encoded.put(
            try allocator.dupe(u8, "case_sensitive"),
            .{ .bool = regex_filter.case_sensitive },
        );
        try encoded_filter.put("regex", .{ .object = encoded });
    }
    if (encoded_filter.count() > 0) {
        try params.putValue("filter", .{ .object = encoded_filter });
    }
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
    try encodeCorrelationKey(Id, params, options.correlation_key);
}

fn encodeCorrelationKey(
    comptime Id: type,
    params: *Params(Id),
    value: ?[]const u8,
) !void {
    if (value) |key| {
        if (key.len == 0 or key.len > 128) {
            return error.InvalidCorrelationKey;
        }
        try params.putString("correlation_key", key);
    }
}

fn encodeTerminalSize(
    comptime Id: type,
    params: *Params(Id),
    cols: ?u16,
    rows: ?u16,
) !void {
    if ((cols == null) != (rows == null)) {
        return error.IncompleteTerminalSize;
    }
    if (cols) |width| {
        if (width == 0 or rows.? == 0) {
            return error.InvalidTerminalSize;
        }
        try params.putValue("cols", .{ .integer = width });
        try params.putValue("rows", .{ .integer = rows.? });
    }
}

fn encodePixelSize(
    comptime Id: type,
    params: *Params(Id),
    width_px: ?u32,
    height_px: ?u32,
) !void {
    if ((width_px == null) != (height_px == null)) {
        return error.IncompleteBrowserSize;
    }
    if (width_px) |width| {
        if (width == 0 or height_px.? == 0) {
            return error.InvalidBrowserSize;
        }
        try params.putValue("width_px", .{ .integer = width });
        try params.putValue("height_px", .{ .integer = height_px.? });
    }
}

fn encodeTerminalTab(
    comptime Id: type,
    params: *Params(Id),
    options: CreateTerminalTabOptions,
) !void {
    if (options.cwd) |cwd| try params.putString("cwd", cwd);
    if (options.name) |name| try params.putString("name", name);
    try encodeTerminalSize(Id, params, options.cols, options.rows);
    try encodeCorrelationKey(Id, params, options.correlation_key);
}

fn encodeBrowserTab(
    comptime Id: type,
    params: *Params(Id),
    options: CreateBrowserTabOptions,
) !void {
    if (options.url.len == 0) return error.InvalidBrowserUrl;
    try params.putString("url", options.url);
    if (options.name) |name| try params.putString("name", name);
    try encodePixelSize(
        Id,
        params,
        options.width_px,
        options.height_px,
    );
    try encodeCorrelationKey(Id, params, options.correlation_key);
}

fn encodeModifiers(
    comptime Id: type,
    params: *Params(Id),
    modifiers: []const InputModifier,
) !void {
    if (modifiers.len == 0) return;
    const allocator = params.arena.allocator();
    var values = std.json.Array.init(allocator);
    for (modifiers) |modifier| {
        try values.append(.{
            .string = try allocator.dupe(u8, modifier.wireName()),
        });
    }
    try params.putValue("modifiers", .{ .array = values });
}

fn encodeOptionalStringUpdate(
    comptime Id: type,
    params: *Params(Id),
    field: []const u8,
    value: OptionalStringUpdate,
) !void {
    switch (value) {
        .unchanged => {},
        .set => |text| try params.putString(field, text),
        .clear => try params.putNull(field),
    }
}

fn encodeTerminalDefaults(
    comptime Id: type,
    params: *Params(Id),
    update: TerminalDefaultsUpdate,
) !void {
    try encodeOptionalStringUpdate(
        Id,
        params,
        "foreground",
        update.foreground,
    );
    try encodeOptionalStringUpdate(
        Id,
        params,
        "background",
        update.background,
    );
    try encodeOptionalStringUpdate(
        Id,
        params,
        "cursor",
        update.cursor,
    );
    try encodeOptionalStringUpdate(
        Id,
        params,
        "selection_background",
        update.selection_background,
    );
    try encodeOptionalStringUpdate(
        Id,
        params,
        "selection_foreground",
        update.selection_foreground,
    );
    switch (update.cursor_style) {
        .unchanged => {},
        .set => |style| try params.putString(
            "cursor_style",
            style.wireName(),
        ),
        .clear => try params.putNull("cursor_style"),
    }
    switch (update.cursor_blink) {
        .unchanged => {},
        .set => |value| try params.putValue(
            "cursor_blink",
            .{ .bool = value },
        ),
        .clear => try params.putNull("cursor_blink"),
    }
    switch (update.palette) {
        .unchanged => {},
        .set => |palette| {
            var iterator = palette.iterator();
            while (iterator.next()) |entry| {
                _ = try validateColorHex(switch (entry.value_ptr.*) {
                    .string => |text| text,
                    else => return error.InvalidPaletteColor,
                });
            }
            try params.putValue("palette", .{ .object = palette });
        },
        .clear => try params.putNull("palette"),
    }
    if (update.complete) |complete| {
        try params.putValue("complete", .{ .bool = complete });
    }
}

fn encodeLayoutNode(
    allocator: std.mem.Allocator,
    node: *const LayoutNode,
) !raw.wire.Value {
    return switch (node.*) {
        .leaf => |leaf| blk: {
            var object = raw.wire.Object.init(allocator);
            try object.put("kind", .{ .string = "leaf" });
            try object.put(
                "pane_id",
                .{ .string = try allocator.dupe(u8, leaf.pane_id.slice()) },
            );
            var tabs = std.json.Array.init(allocator);
            for (leaf.tab_ids) |tab| {
                try tabs.append(.{
                    .string = try allocator.dupe(u8, tab.slice()),
                });
            }
            try object.put("tab_ids", .{ .array = tabs });
            try object.put(
                "active_tab_id",
                if (leaf.active_tab_id) |*tab|
                    .{ .string = try allocator.dupe(u8, tab.slice()) }
                else
                    .null,
            );
            break :blk .{ .object = object };
        },
        .split => |split| blk: {
            if (!std.math.isFinite(split.ratio) or
                split.ratio <= 0 or split.ratio >= 1)
            {
                return error.InvalidLayoutRatio;
            }
            var object = raw.wire.Object.init(allocator);
            try object.put("kind", .{ .string = "split" });
            try object.put(
                "split_id",
                .{ .string = try allocator.dupe(
                    u8,
                    split.split_id.slice(),
                ) },
            );
            try object.put(
                "direction",
                .{ .string = try allocator.dupe(
                    u8,
                    split.direction.wireName(),
                ) },
            );
            try object.put("ratio", .{ .float = split.ratio });
            try object.put(
                "first",
                try encodeLayoutNode(allocator, split.first),
            );
            try object.put(
                "second",
                try encodeLayoutNode(allocator, split.second),
            );
            break :blk .{ .object = object };
        },
        .stack => |stack| blk: {
            var object = raw.wire.Object.init(allocator);
            try object.put("kind", .{ .string = "stack" });
            var panes = std.json.Array.init(allocator);
            for (stack.pane_ids) |pane| {
                try panes.append(.{
                    .string = try allocator.dupe(u8, pane.slice()),
                });
            }
            try object.put("pane_ids", .{ .array = panes });
            try object.put(
                "expanded_pane_id",
                .{ .string = try allocator.dupe(
                    u8,
                    stack.expanded_pane_id.slice(),
                ) },
            );
            break :blk .{ .object = object };
        },
        .viewport => |viewport| blk: {
            var object = raw.wire.Object.init(allocator);
            try object.put("kind", .{ .string = "viewport" });
            try object.put(
                "base_width",
                .{ .float = viewport.base_width },
            );
            var columns = std.json.Array.init(allocator);
            for (viewport.columns) |column| {
                var encoded = raw.wire.Object.init(allocator);
                try encoded.put(
                    "column_id",
                    .{ .string = try allocator.dupe(
                        u8,
                        column.column_id.slice(),
                    ) },
                );
                try encoded.put("width", .{ .float = column.width });
                try encoded.put(
                    "root",
                    try encodeLayoutNode(allocator, column.root),
                );
                try columns.append(.{ .object = encoded });
            }
            try object.put("columns", .{ .array = columns });
            break :blk .{ .object = object };
        },
        .unknown => |unknown| try raw.wire.cloneValue(
            allocator,
            unknown.raw_object,
        ),
    };
}

fn encodeLayoutDocument(
    allocator: std.mem.Allocator,
    document: LayoutDocument,
) !raw.wire.Value {
    var object = raw.wire.Object.init(allocator);
    try object.put("version", .{ .integer = document.version });
    try object.put(
        "screen_id",
        .{ .string = try allocator.dupe(u8, document.screen_id.slice()) },
    );
    try object.put(
        "active_pane_id",
        .{ .string = try allocator.dupe(
            u8,
            document.active_pane_id.slice(),
        ) },
    );
    try object.put(
        "zoomed_pane_id",
        if (document.zoomed_pane_id) |*pane|
            .{ .string = try allocator.dupe(u8, pane.slice()) }
        else
            .null,
    );
    try object.put(
        "root",
        try encodeLayoutNode(allocator, document.root),
    );
    if (document.extra) |extra| {
        try object.put(
            "extra",
            try raw.wire.cloneValue(
                allocator,
                .{ .object = extra },
            ),
        );
    }
    return .{ .object = object };
}

fn encodeMoveDestination(
    comptime Id: type,
    params: *Params(Id),
    destination: MoveDestination,
) !void {
    try params.putString(
        "destination_workspace",
        destination.workspace.slice(),
    );
    try params.putString(
        "destination_screen",
        destination.screen.slice(),
    );
    try params.putString(
        "destination_pane",
        destination.pane.slice(),
    );
    if (destination.index) |index| {
        try params.putValue("index", .{ .integer = index });
    }
}

pub const MachineOrigin = union(enum) {
    local,
    unknown: []const u8,

    pub fn wireName(self: MachineOrigin) []const u8 {
        return switch (self) {
            .local => "local",
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

pub const TerminalExitOutcome = union(enum) {
    exit: i32,
    signal: struct {
        signal: i32,
        core_dumped: bool,
    },
    unknown: []const u8,
};

pub const TerminalExit = struct {
    outcome: TerminalExitOutcome,
    exited_at: u64,
    revision: u64,
};

pub const TerminalLifecycle = union(enum) {
    launching,
    running,
    exited,
    unknown: []const u8,

    pub fn wireName(self: TerminalLifecycle) []const u8 {
        return switch (self) {
            inline .launching, .running, .exited => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const TerminalSnapshot = struct {
    id: TerminalId,
    tab_ids: []const TabId,
    title: []const u8,
    cwd: ?[]const u8,
    cols: u16,
    rows: u16,
    running: bool,
    lifecycle: TerminalLifecycle,
    exit: ?TerminalExit,
    extra: ?raw.wire.Object,
};

pub const NotificationLevel = union(enum) {
    info,
    warning,
    @"error",
    unknown: []const u8,

    pub fn wireName(self: NotificationLevel) []const u8 {
        return switch (self) {
            inline .info, .warning, .@"error" => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const NotificationSnapshot = struct {
    id: NotificationId,
    session_id: SessionId,
    title: []const u8,
    body: []const u8,
    level: NotificationLevel,
    terminal_id: ?TerminalId,
    created_at_ms: u64,
    unread: bool,
    extra: ?raw.wire.Object,
};

pub const AgentState = union(enum) {
    working,
    blocked,
    idle,
    done,
    unknown,
    unrecognized: []const u8,

    pub fn wireName(self: AgentState) []const u8 {
        return switch (self) {
            inline .working, .blocked, .idle, .done, .unknown => |_, tag| @tagName(tag),
            .unrecognized => |value| value,
        };
    }
};

pub const AgentSource = union(enum) {
    hook,
    socket,
    detected,
    unknown: []const u8,

    pub fn wireName(self: AgentSource) []const u8 {
        return switch (self) {
            inline .hook, .socket, .detected => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const AgentSnapshot = struct {
    id: AgentId,
    session_id: SessionId,
    terminal_id: TerminalId,
    state: AgentState,
    source: AgentSource,
    updated_at_ms: u64,
    source_session: ?[]const u8,
    extra: ?raw.wire.Object,
};

pub const PairingStatus = union(enum) {
    pending,
    accepted,
    rejected,
    unknown: []const u8,

    pub fn wireName(self: PairingStatus) []const u8 {
        return switch (self) {
            inline .pending, .accepted, .rejected => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const PairingDecision = enum {
    accept,
    reject,
};

pub const PairingRequestSnapshot = struct {
    id: PairingRequestId,
    session_id: SessionId,
    peer: []const u8,
    code: SensitiveString,
    expires_in_seconds: u64,
    status: PairingStatus,
    extra: ?raw.wire.Object,

    pub fn format(
        _: PairingRequestSnapshot,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("PairingRequestSnapshot{code=[REDACTED]}");
    }
};

pub const PairingResolutionResult = struct {
    pairing_request: PairingRequestSnapshot,
};

pub const FrontendProjectionSnapshot = struct {
    id: FrontendProjectionId,
    session_id: SessionId,
    frontend_id: []const u8,
    window_id: []const u8,
    generation: []const u8,
    projection: raw.wire.Value,
    projection_revision: u64,
    extra: ?raw.wire.Object,
};

pub const ProjectionPutOptions = struct {
    frontend_id: []const u8,
    window_id: []const u8,
    generation: []const u8,
    projection: raw.wire.Value,
    expected_projection_revision: ?u64 = null,
};

pub const SidebarViewSnapshot = struct {
    id: SidebarViewId,
    session_id: SessionId,
    cols: u16,
    rows: u16,
    running: bool,
    extra: ?raw.wire.Object,
};

pub const CreationState = union(enum) {
    pending,
    created,
    not_applied,
    indeterminate,
    unknown: []const u8,

    pub fn wireName(self: CreationState) []const u8 {
        return switch (self) {
            inline .pending, .created, .not_applied, .indeterminate => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const CreationRecovery = union(enum) {
    retry_same_idempotency_key,
    retry_new_idempotency_key,
    wait,
    none,
    do_not_retry,
    unknown: []const u8,

    pub fn wireName(self: CreationRecovery) []const u8 {
        return switch (self) {
            inline .retry_same_idempotency_key,
            .retry_new_idempotency_key,
            .wait,
            .none,
            .do_not_retry,
            => |_, tag| @tagName(tag),
            .unknown => |value| value,
        };
    }
};

pub const CreationResolution = struct {
    correlation_key: []const u8,
    state: CreationState,
    recovery: CreationRecovery,
    operation: ?[]const u8,
    idempotency_key: ?[]const u8,
    created_path: ?CreatedPath,
    generation: ?[]const u8,
    revision: ?u64,
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
    outcome: ViewAttachmentOutcome,
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

pub const TerminalWaitExitPending = struct {
    terminal_id: TerminalId,
    lifecycle: TerminalLifecycle,
    revision: u64,
};

pub const TerminalWaitExitExited = struct {
    terminal_id: TerminalId,
    outcome: TerminalExitOutcome,
    exited_at: u64,
    revision: u64,
};

pub const TerminalWaitExitResult = union(enum) {
    pending: TerminalWaitExitPending,
    exited: TerminalWaitExitExited,
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
    /// Working directory of the process group that owns the PTY, read at
    /// request time. Null when the lookup fails or when an older server
    /// omits the field.
    foreground_cwd: ?[]const u8,
    children: []const u32,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
};

pub const ViewerResizeResult = struct {
    accepted: bool,
    size: Size,
    outcome: ViewAttachmentOutcome,
};

pub const ViewAttachmentOutcome = enum {
    applied,
    passive,
    superseded,
};

pub const ViewerReleaseResult = struct {
    outcome: ViewAttachmentOutcome,
};

pub const PaneNeighborResult = struct {
    pane: ?PaneSnapshot,
};

pub const ShutdownResult = struct {
    accepted: bool,
};

pub const ReloadConfigResult = struct {
    reloaded: bool,
    warnings: []const []const u8,
};

pub const TerminalDefaultsSnapshot = struct {
    foreground: OptionalStringUpdate,
    background: OptionalStringUpdate,
    cursor: OptionalStringUpdate,
    selection_background: OptionalStringUpdate,
    selection_foreground: OptionalStringUpdate,
    cursor_style: OptionalCursorStyleUpdate,
    cursor_blink: OptionalBoolUpdate,
    palette: OptionalPaletteUpdate,
};

pub const ResourceSnapshot = struct {
    machine: MachineSnapshot,
    session: SessionSnapshot,
    workspaces: []const WorkspaceSnapshot,
    screens: []const ScreenSnapshot,
    panes: []const PaneSnapshot,
    tabs: []const TabSnapshot,
    terminals: []const TerminalSnapshot,
    browsers: []const BrowserSnapshot,
    clients: []const ClientSnapshot,
    notifications: []const NotificationSnapshot,
    agents: []const AgentSnapshot,
    frontend_projections: []const FrontendProjectionSnapshot,
    sidebar_views: []const SidebarViewSnapshot,
    cursor: Cursor,
    extra: ?raw.wire.Object,
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

fn OwnedDecodedList(comptime Item: type) type {
    return struct {
        const Self = @This();

        owned: raw.wire.OwnedValue,
        decoded: std.heap.ArenaAllocator,
        items: []const Item,

        pub fn deinit(self: *Self) void {
            self.decoded.deinit();
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
pub const OwnedTerminalSnapshot = OwnedDecodedValue(TerminalSnapshot);
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
pub const OwnedTerminalWaitExitResult =
    OwnedValue(TerminalWaitExitResult);
pub const OwnedTerminalCopyResult = OwnedValue(TerminalCopyResult);
pub const OwnedProcessInfoResult = OwnedDecodedValue(ProcessInfoResult);
pub const OwnedViewerResizeResult = OwnedValue(ViewerResizeResult);
pub const OwnedViewerReleaseResult = OwnedValue(ViewerReleaseResult);
pub const OwnedBrowserViewerResizeResult =
    OwnedValue(BrowserViewerResizeResult);
pub const OwnedCellPixelsResult = OwnedDecodedValue(CellPixelsResult);
pub const OwnedPaneNeighborResult = OwnedValue(PaneNeighborResult);
pub const OwnedCreationResolution = OwnedValue(CreationResolution);
pub const OwnedResourceSnapshot = OwnedDecodedValue(ResourceSnapshot);
pub const OwnedReloadConfigResult =
    OwnedDecodedValue(ReloadConfigResult);
pub const OwnedLayoutDocument = OwnedDecodedValue(LayoutDocument);
pub const OwnedFrontendProjectionSnapshot =
    OwnedValue(FrontendProjectionSnapshot);
pub const OwnedPairingResolutionResult =
    OwnedValue(PairingResolutionResult);
pub const MachineList = OwnedList(MachineSnapshot);
pub const SessionList = OwnedList(SessionSnapshot);
pub const WorkspaceList = OwnedList(WorkspaceSnapshot);
pub const ScreenList = OwnedDecodedList(ScreenSnapshot);
pub const PaneList = OwnedList(PaneSnapshot);
pub const TabList = OwnedList(TabSnapshot);
pub const TerminalList = OwnedDecodedList(TerminalSnapshot);
pub const BrowserList = OwnedList(BrowserSnapshot);
pub const ClientList = OwnedDecodedList(ClientSnapshot);
pub const NotificationList = OwnedList(NotificationSnapshot);
pub const AgentList = OwnedList(AgentSnapshot);
pub const PairingRequestList = OwnedList(PairingRequestSnapshot);
pub const SessionMutationResult = TypedMutationResult(SessionSnapshot);
pub const WorkspaceMutationResult = TypedMutationResult(WorkspaceSnapshot);
pub const TerminalMutationResult =
    TypedDecodedMutationResult(TerminalSnapshot);
pub const BrowserMutationResult = TypedMutationResult(BrowserSnapshot);
pub const ScreenMutationResult =
    TypedDecodedMutationResult(ScreenSnapshot);
pub const PaneMutationResult = TypedMutationResult(PaneSnapshot);
pub const TabMutationResult = TypedMutationResult(TabSnapshot);
pub const NotificationMutationResult =
    TypedMutationResult(NotificationSnapshot);
pub const AgentMutationResult = TypedMutationResult(AgentSnapshot);
pub const PairingResolutionMutationResult =
    TypedMutationResult(PairingResolutionResult);
pub const FrontendProjectionMutationResult =
    TypedMutationResult(FrontendProjectionSnapshot);
pub const SidebarViewMutationResult =
    TypedMutationResult(SidebarViewSnapshot);
pub const ShutdownMutationResult = TypedMutationResult(ShutdownResult);
pub const ReloadConfigMutationResult =
    TypedDecodedMutationResult(ReloadConfigResult);
pub const TerminalDefaultsMutationResult =
    TypedMutationResult(TerminalDefaultsSnapshot);
pub const CreatedPathMutationResult = TypedMutationResult(CreatedPath);
pub const CreatedTerminalPathMutationResult =
    TypedMutationResult(CreatedTerminalPath);
pub const CreatedBrowserPathMutationResult =
    TypedMutationResult(CreatedBrowserPath);
pub const EmptyMutationResult = TypedMutationResult(EmptyResult);

fn parseMachineOrigin(value: []const u8) MachineOrigin {
    if (std.mem.eql(u8, value, "local")) return .local;
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
    const wire_value: u64 = switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse
            return error.IntegerOverflow,
        .number_string => |text| try std.fmt.parseInt(u64, text, 10),
        else => return error.ExpectedUnsignedInteger,
    };
    const decoded = std.math.cast(
        Int,
        wire_value,
    ) orelse return error.IntegerOverflow;
    if (decoded < minimum) return error.IntegerOutOfRange;
    return decoded;
}

fn signedValue(comptime Int: type, value: raw.wire.Value) !Int {
    const decoded = switch (value) {
        .integer => |number| number,
        .number_string => |text| try std.fmt.parseInt(i64, text, 10),
        else => return error.ExpectedInteger,
    };
    return std.math.cast(Int, decoded) orelse error.IntegerOverflow;
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

fn optionalNullableString(
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

fn requiredNullableDecimalU64(
    object: raw.wire.Object,
    name: []const u8,
) !?u64 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .null => null,
        else => try decimalU64(value),
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

fn parseTerminalLifecycle(value: []const u8) TerminalLifecycle {
    if (std.mem.eql(u8, value, "launching")) return .launching;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "exited")) return .exited;
    return .{ .unknown = value };
}

fn parseNotificationLevel(value: []const u8) NotificationLevel {
    if (std.mem.eql(u8, value, "info")) return .info;
    if (std.mem.eql(u8, value, "warning")) return .warning;
    if (std.mem.eql(u8, value, "error")) return .@"error";
    return .{ .unknown = value };
}

fn parseAgentState(value: []const u8) AgentState {
    if (std.mem.eql(u8, value, "working")) return .working;
    if (std.mem.eql(u8, value, "blocked")) return .blocked;
    if (std.mem.eql(u8, value, "idle")) return .idle;
    if (std.mem.eql(u8, value, "done")) return .done;
    if (std.mem.eql(u8, value, "unknown")) return .unknown;
    return .{ .unrecognized = value };
}

fn parseAgentSource(value: []const u8) AgentSource {
    if (std.mem.eql(u8, value, "hook")) return .hook;
    if (std.mem.eql(u8, value, "socket")) return .socket;
    if (std.mem.eql(u8, value, "detected")) return .detected;
    return .{ .unknown = value };
}

fn parsePairingStatus(value: []const u8) PairingStatus {
    if (std.mem.eql(u8, value, "pending")) return .pending;
    if (std.mem.eql(u8, value, "accepted")) return .accepted;
    if (std.mem.eql(u8, value, "rejected")) return .rejected;
    return .{ .unknown = value };
}

fn parseCreationState(value: []const u8) CreationState {
    if (std.mem.eql(u8, value, "pending")) return .pending;
    if (std.mem.eql(u8, value, "created")) return .created;
    if (std.mem.eql(u8, value, "not_applied")) return .not_applied;
    if (std.mem.eql(u8, value, "indeterminate")) return .indeterminate;
    return .{ .unknown = value };
}

fn parseCreationRecovery(value: []const u8) CreationRecovery {
    if (std.mem.eql(u8, value, "retry_same_idempotency_key")) {
        return .retry_same_idempotency_key;
    }
    if (std.mem.eql(u8, value, "retry_new_idempotency_key")) {
        return .retry_new_idempotency_key;
    }
    if (std.mem.eql(u8, value, "wait")) return .wait;
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "do_not_retry")) return .do_not_retry;
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
    try ensureOnlyFields(object, &.{ "accepted", "size", "outcome" });
    return .{
        .accepted = try objectBool(object, "accepted"),
        .size = try decodePixelSize(
            object.get("size") orelse return error.MissingField,
        ),
        .outcome = try decodeViewAttachmentOutcome(
            try objectString(object, "outcome"),
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

fn decodeTerminalWaitExitResult(
    value: raw.wire.Value,
) !TerminalWaitExitResult {
    const object = try detailObject(value);
    const state = try objectString(object, "state");
    if (std.mem.eql(u8, state, "pending")) {
        try ensureOnlyFields(
            object,
            &.{ "state", "terminal_id", "lifecycle", "revision" },
        );
        const lifecycle = parseTerminalLifecycle(
            try objectString(object, "lifecycle"),
        );
        switch (lifecycle) {
            .launching, .running => {},
            else => return error.InvalidTerminalLifecycle,
        }
        return .{ .pending = .{
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
            .lifecycle = lifecycle,
            .revision = try decimalU64(
                object.get("revision") orelse return error.MissingField,
            ),
        } };
    }
    if (std.mem.eql(u8, state, "exited")) {
        try ensureOnlyFields(
            object,
            &.{
                "state",
                "terminal_id",
                "lifecycle",
                "outcome",
                "exited_at",
                "revision",
            },
        );
        if (!std.mem.eql(
            u8,
            try objectString(object, "lifecycle"),
            "exited",
        )) {
            return error.InvalidTerminalLifecycle;
        }
        return .{ .exited = .{
            .terminal_id = try parseRequiredId(
                TerminalId,
                object,
                "terminal_id",
            ),
            .outcome = try decodeTerminalExitOutcome(
                object.get("outcome") orelse return error.MissingField,
            ),
            .exited_at = try decimalU64(
                object.get("exited_at") orelse return error.MissingField,
            ),
            .revision = try decimalU64(
                object.get("revision") orelse return error.MissingField,
            ),
        } };
    }
    return error.UnknownTerminalWaitExitState;
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
        &.{ "pid", "executable", "argv", "cwd", "foreground_cwd", "children" },
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
        .foreground_cwd = try optionalNullableString(object, "foreground_cwd"),
        .children = children,
    };
}

fn decodeViewerResizeResult(
    value: raw.wire.Value,
) !ViewerResizeResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "accepted", "size", "outcome" });
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
        .outcome = try decodeViewAttachmentOutcome(
            try objectString(object, "outcome"),
        ),
    };
}

fn decodeViewAttachmentOutcome(
    value: []const u8,
) !ViewAttachmentOutcome {
    if (std.mem.eql(u8, value, "applied")) return .applied;
    if (std.mem.eql(u8, value, "passive")) return .passive;
    if (std.mem.eql(u8, value, "superseded")) return .superseded;
    return error.InvalidViewAttachmentOutcome;
}

fn decodeViewerReleaseResult(
    value: raw.wire.Value,
) !ViewerReleaseResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{"outcome"});
    return .{
        .outcome = try decodeViewAttachmentOutcome(
            try objectString(object, "outcome"),
        ),
    };
}

fn decodePaneNeighborResult(
    value: raw.wire.Value,
) !PaneNeighborResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{"pane"});
    const pane = if (object.get("pane")) |item|
        switch (item) {
            .null => null,
            else => try decodePaneSnapshot(item),
        }
    else
        null;
    return .{ .pane = pane };
}

fn decodePairingResolutionResult(
    value: raw.wire.Value,
) !PairingResolutionResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{"pairing_request"});
    return .{
        .pairing_request = try decodePairingRequestSnapshot(
            object.get("pairing_request") orelse
                return error.MissingField,
        ),
    };
}

fn decodeShutdownResult(value: raw.wire.Value) !ShutdownResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{"accepted"});
    return .{ .accepted = try objectBool(object, "accepted") };
}

fn decodeReloadConfigResult(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ReloadConfigResult {
    const object = try detailObject(value);
    try ensureOnlyFields(object, &.{ "reloaded", "warnings" });
    const raw_warnings = switch (object.get("warnings") orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const warnings = try allocator.alloc(
        []const u8,
        raw_warnings.len,
    );
    for (raw_warnings, 0..) |warning, index| {
        warnings[index] = switch (warning) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
    }
    return .{
        .reloaded = try objectBool(object, "reloaded"),
        .warnings = warnings,
    };
}

fn decodeOptionalStringUpdate(
    object: raw.wire.Object,
    name: []const u8,
) !OptionalStringUpdate {
    const value = object.get(name) orelse return .unchanged;
    return switch (value) {
        .null => .clear,
        .string => |text| .{ .set = text },
        else => error.ExpectedString,
    };
}

fn decodeOptionalCursorStyleUpdate(
    object: raw.wire.Object,
    name: []const u8,
) !OptionalCursorStyleUpdate {
    const value = object.get(name) orelse return .unchanged;
    return switch (value) {
        .null => .clear,
        .string => |text| .{ .set = if (std.mem.eql(u8, text, "block"))
            .block
        else if (std.mem.eql(u8, text, "bar"))
            .bar
        else if (std.mem.eql(u8, text, "underline"))
            .underline
        else
            .{ .unknown = text } },
        else => error.ExpectedString,
    };
}

fn decodeOptionalBoolUpdate(
    object: raw.wire.Object,
    name: []const u8,
) !OptionalBoolUpdate {
    const value = object.get(name) orelse return .unchanged;
    return switch (value) {
        .null => .clear,
        .bool => |item| .{ .set = item },
        else => error.ExpectedBool,
    };
}

fn decodeOptionalPaletteUpdate(
    object: raw.wire.Object,
    name: []const u8,
) !OptionalPaletteUpdate {
    const value = object.get(name) orelse return .unchanged;
    return switch (value) {
        .null => .clear,
        .object => |item| .{ .set = item },
        else => error.ExpectedObject,
    };
}

fn decodeTerminalDefaultsSnapshot(
    value: raw.wire.Value,
) !TerminalDefaultsSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "foreground",
            "background",
            "cursor",
            "selection_background",
            "selection_foreground",
            "cursor_style",
            "cursor_blink",
            "palette",
        },
    );
    return .{
        .foreground = try decodeOptionalStringUpdate(
            object,
            "foreground",
        ),
        .background = try decodeOptionalStringUpdate(
            object,
            "background",
        ),
        .cursor = try decodeOptionalStringUpdate(object, "cursor"),
        .selection_background = try decodeOptionalStringUpdate(
            object,
            "selection_background",
        ),
        .selection_foreground = try decodeOptionalStringUpdate(
            object,
            "selection_foreground",
        ),
        .cursor_style = try decodeOptionalCursorStyleUpdate(
            object,
            "cursor_style",
        ),
        .cursor_blink = try decodeOptionalBoolUpdate(
            object,
            "cursor_blink",
        ),
        .palette = try decodeOptionalPaletteUpdate(object, "palette"),
    };
}

fn decodeMachineSnapshot(value: raw.wire.Value) !MachineSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "name",
            "origin",
            "status",
            "connectable",
            "deleted",
            "recoverable",
            "extra",
        },
    );
    return .{
        .id = try parseRequiredId(MachineId, object, "id"),
        .name = try objectString(object, "name"),
        .origin = parseMachineOrigin(try objectString(object, "origin")),
        .status = parseMachineStatus(try objectString(object, "status")),
        .connectable = try objectBool(object, "connectable"),
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
    return .{
        .id = try parseRequiredId(WorkspaceId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .name = try objectString(object, "name"),
        .index = try objectUnsigned(u32, object, "index", 0),
        .focused = try objectBool(object, "focused"),
        .extra = try optionalExtra(object),
    };
}

fn decodeTerminalExitOutcome(
    value: raw.wire.Value,
) !TerminalExitOutcome {
    const object = try detailObject(value);
    const kind = try objectString(object, "kind");
    if (std.mem.eql(u8, kind, "exit")) {
        try ensureOnlyFields(object, &.{ "kind", "code" });
        return .{ .exit = try signedValue(
            i32,
            object.get("code") orelse return error.MissingField,
        ) };
    }
    if (std.mem.eql(u8, kind, "signal")) {
        try ensureOnlyFields(
            object,
            &.{ "kind", "signal", "core_dumped" },
        );
        const signal = try signedValue(
            i32,
            object.get("signal") orelse return error.MissingField,
        );
        if (signal < 1) return error.IntegerOutOfRange;
        return .{ .signal = .{
            .signal = signal,
            .core_dumped = try objectBool(object, "core_dumped"),
        } };
    }
    if (std.mem.eql(u8, kind, "unknown")) {
        try ensureOnlyFields(object, &.{ "kind", "reason" });
        const reason = try objectString(object, "reason");
        if (reason.len == 0) return error.ExpectedNonEmptyString;
        return .{ .unknown = reason };
    }
    return error.UnknownTerminalExitKind;
}

fn decodeTerminalExit(value: raw.wire.Value) !TerminalExit {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "outcome", "exited_at", "revision" },
    );
    return .{
        .outcome = try decodeTerminalExitOutcome(
            object.get("outcome") orelse return error.MissingField,
        ),
        .exited_at = try decimalU64(
            object.get("exited_at") orelse return error.MissingField,
        ),
        .revision = try decimalU64(
            object.get("revision") orelse return error.MissingField,
        ),
    };
}

fn decodeTerminalSnapshot(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !TerminalSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "tab_id",
            "tab_ids",
            "title",
            "cwd",
            "cols",
            "rows",
            "running",
            "lifecycle",
            "exit",
            "extra",
        },
    );
    const terminal_exit = if (object.get("exit")) |item|
        try decodeTerminalExit(item)
    else
        null;
    const running = try objectBool(object, "running");
    const lifecycle = parseTerminalLifecycle(
        try objectString(object, "lifecycle"),
    );
    if (running != (lifecycle == .running) or
        ((terminal_exit != null) != (lifecycle == .exited)))
    {
        return error.InvalidTerminalState;
    }
    const legacy_field = object.get("tab_id");
    const legacy_tab_id: ?TabId = if (legacy_field != null)
        try requiredNullableId(TabId, object, "tab_id")
    else
        null;
    const raw_tab_ids: ?[]const raw.wire.Value = if (object.get("tab_ids")) |raw_value|
        switch (raw_value) {
            .array => |items| items.items,
            else => return error.ExpectedArray,
        }
    else
        null;
    if (legacy_field == null and raw_tab_ids == null) return error.MissingField;
    const tab_ids = try allocator.alloc(
        TabId,
        if (raw_tab_ids) |items| items.len else if (legacy_tab_id != null) 1 else 0,
    );
    errdefer allocator.free(tab_ids);
    if (raw_tab_ids) |items| {
        for (items, 0..) |item, index| {
            tab_ids[index] = switch (item) {
                .string => |text| try TabId.parse(text),
                else => return error.ExpectedString,
            };
        }
    } else if (legacy_tab_id) |tab_id| {
        tab_ids[0] = tab_id;
    }
    if (legacy_field != null and
        ((legacy_tab_id == null) != (tab_ids.len == 0) or
            (legacy_tab_id != null and !std.meta.eql(legacy_tab_id.?, tab_ids[0]))))
    {
        return error.InvalidTerminalPlacement;
    }
    return .{
        .id = try parseRequiredId(TerminalId, object, "id"),
        .tab_ids = tab_ids,
        .title = try objectString(object, "title"),
        .cwd = try strictOptionalString(object, "cwd"),
        .cols = try objectUnsigned(u16, object, "cols", 1),
        .rows = try objectUnsigned(u16, object, "rows", 1),
        .running = running,
        .lifecycle = lifecycle,
        .exit = terminal_exit,
        .extra = try optionalExtra(object),
    };
}

fn decodeNotificationSnapshot(
    value: raw.wire.Value,
) !NotificationSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "session_id",
            "title",
            "body",
            "level",
            "terminal_id",
            "created_at_ms",
            "unread",
            "extra",
        },
    );
    return .{
        .id = try parseRequiredId(NotificationId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .title = try objectString(object, "title"),
        .body = try objectString(object, "body"),
        .level = parseNotificationLevel(
            try objectString(object, "level"),
        ),
        .terminal_id = try strictOptionalId(
            TerminalId,
            object,
            "terminal_id",
        ),
        .created_at_ms = try decimalU64(
            object.get("created_at_ms") orelse return error.MissingField,
        ),
        .unread = try objectBool(object, "unread"),
        .extra = try optionalExtra(object),
    };
}

fn decodeAgentSnapshot(value: raw.wire.Value) !AgentSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "session_id",
            "terminal_id",
            "state",
            "source",
            "updated_at_ms",
            "source_session",
            "extra",
        },
    );
    return .{
        .id = try parseRequiredId(AgentId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .terminal_id = try parseRequiredId(
            TerminalId,
            object,
            "terminal_id",
        ),
        .state = parseAgentState(try objectString(object, "state")),
        .source = parseAgentSource(try objectString(object, "source")),
        .updated_at_ms = try decimalU64(
            object.get("updated_at_ms") orelse return error.MissingField,
        ),
        .source_session = try requiredNullableString(
            object,
            "source_session",
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodePairingRequestSnapshot(
    value: raw.wire.Value,
) !PairingRequestSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",
            "session_id",
            "peer",
            "code",
            "expires_in_seconds",
            "status",
            "extra",
        },
    );
    return .{
        .id = try parseRequiredId(PairingRequestId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .peer = try objectString(object, "peer"),
        .code = .{ .bytes = try objectString(object, "code") },
        .expires_in_seconds = try decimalU64(
            object.get("expires_in_seconds") orelse
                return error.MissingField,
        ),
        .status = parsePairingStatus(
            try objectString(object, "status"),
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodeFrontendProjectionSnapshot(
    value: raw.wire.Value,
) !FrontendProjectionSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "id",         "session_id",          "frontend_id", "window_id", "generation",
            "projection", "projection_revision", "extra",
        },
    );
    return .{
        .id = try parseRequiredId(
            FrontendProjectionId,
            object,
            "id",
        ),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .frontend_id = try objectString(object, "frontend_id"),
        .window_id = try objectString(object, "window_id"),
        .generation = try objectString(object, "generation"),
        .projection = object.get("projection") orelse
            return error.MissingField,
        .projection_revision = try decimalU64(
            object.get("projection_revision") orelse
                return error.MissingField,
        ),
        .extra = try optionalExtra(object),
    };
}

fn decodeSidebarViewSnapshot(
    value: raw.wire.Value,
) !SidebarViewSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{ "id", "session_id", "cols", "rows", "running", "extra" },
    );
    return .{
        .id = try parseRequiredId(SidebarViewId, object, "id"),
        .session_id = try parseRequiredId(
            SessionId,
            object,
            "session_id",
        ),
        .cols = try objectUnsigned(u16, object, "cols", 1),
        .rows = try objectUnsigned(u16, object, "rows", 1),
        .running = try objectBool(object, "running"),
        .extra = try optionalExtra(object),
    };
}

fn decodeCreationResolution(
    value: raw.wire.Value,
) !CreationResolution {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "correlation_key",
            "state",
            "recovery",
            "operation",
            "idempotency_key",
            "created_path",
            "generation",
            "revision",
        },
    );
    const correlation_key = try objectString(object, "correlation_key");
    if (correlation_key.len == 0 or correlation_key.len > 128) {
        return error.InvalidCorrelationKey;
    }
    const state = parseCreationState(try objectString(object, "state"));
    const recovery = parseCreationRecovery(
        try objectString(object, "recovery"),
    );
    const created_path = if (object.get("created_path")) |item|
        try parseCreatedPath(item)
    else
        null;
    const revision = if (object.get("revision")) |item|
        try decimalU64(item)
    else
        null;
    const operation = try strictOptionalString(object, "operation");
    const idempotency_key = try strictOptionalString(
        object,
        "idempotency_key",
    );
    const generation = try strictOptionalString(object, "generation");
    if (operation) |item| {
        if (item.len == 0) return error.ExpectedNonEmptyString;
    }
    if (idempotency_key) |item| {
        if (item.len == 0 or item.len > 128) {
            return error.InvalidIdempotencyKey;
        }
    }
    if (generation) |item| {
        if (item.len == 0 or item.len > 128) {
            return error.InvalidMutationGeneration;
        }
    }
    switch (state) {
        .created => {
            if (created_path == null or generation == null or
                revision == null)
            {
                return error.InvalidCreationResolution;
            }
            switch (recovery) {
                .none => {},
                else => return error.InvalidCreationResolution,
            }
        },
        .pending => switch (recovery) {
            .wait => {},
            else => return error.InvalidCreationResolution,
        },
        .not_applied => switch (recovery) {
            .retry_same_idempotency_key,
            .retry_new_idempotency_key,
            => {},
            else => return error.InvalidCreationResolution,
        },
        .indeterminate => switch (recovery) {
            .do_not_retry => {},
            else => return error.InvalidCreationResolution,
        },
        .unknown => {},
    }
    return .{
        .correlation_key = correlation_key,
        .state = state,
        .recovery = recovery,
        .operation = operation,
        .idempotency_key = idempotency_key,
        .created_path = created_path,
        .generation = generation,
        .revision = revision,
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
    if (comptime Snapshot == NotificationSnapshot) {
        return decodeNotificationSnapshot(value);
    }
    if (comptime Snapshot == AgentSnapshot) {
        return decodeAgentSnapshot(value);
    }
    if (comptime Snapshot == PairingRequestSnapshot) {
        return decodePairingRequestSnapshot(value);
    }
    if (comptime Snapshot == FrontendProjectionSnapshot) {
        return decodeFrontendProjectionSnapshot(value);
    }
    if (comptime Snapshot == SidebarViewSnapshot) {
        return decodeSidebarViewSnapshot(value);
    }
    @compileError("unsupported typed resource snapshot");
}

fn decodeArenaSnapshot(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !Snapshot {
    if (comptime Snapshot == ScreenSnapshot) {
        return decodeScreenSnapshot(allocator, value);
    }
    if (comptime Snapshot == ClientSnapshot) {
        return decodeClientSnapshot(allocator, value);
    }
    if (comptime Snapshot == TerminalSnapshot) {
        return decodeTerminalSnapshot(allocator, value);
    }
    return decodeTypedSnapshot(Snapshot, value);
}

fn decodeSnapshotArray(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    object: raw.wire.Object,
    field: []const u8,
) ![]const Snapshot {
    const raw_items = switch (object.get(field) orelse
        return error.MissingField) {
        .array => |items| items.items,
        else => return error.ExpectedArray,
    };
    const items = try allocator.alloc(Snapshot, raw_items.len);
    for (raw_items, 0..) |item, index| {
        items[index] = try decodeArenaSnapshot(
            Snapshot,
            allocator,
            item,
        );
    }
    return items;
}

fn decodeResourceSnapshot(
    allocator: std.mem.Allocator,
    value: raw.wire.Value,
) !ResourceSnapshot {
    const object = try detailObject(value);
    try ensureOnlyFields(
        object,
        &.{
            "machine",
            "session",
            "workspaces",
            "screens",
            "panes",
            "tabs",
            "terminals",
            "browsers",
            "clients",
            "notifications",
            "agents",
            "frontend_projections",
            "sidebar_views",
            "cursor",
            "extra",
        },
    );
    return .{
        .machine = try decodeMachineSnapshot(
            object.get("machine") orelse return error.MissingField,
        ),
        .session = try decodeSessionSnapshot(
            object.get("session") orelse return error.MissingField,
        ),
        .workspaces = try decodeSnapshotArray(
            WorkspaceSnapshot,
            allocator,
            object,
            "workspaces",
        ),
        .screens = try decodeSnapshotArray(
            ScreenSnapshot,
            allocator,
            object,
            "screens",
        ),
        .panes = try decodeSnapshotArray(
            PaneSnapshot,
            allocator,
            object,
            "panes",
        ),
        .tabs = try decodeSnapshotArray(
            TabSnapshot,
            allocator,
            object,
            "tabs",
        ),
        .terminals = try decodeSnapshotArray(
            TerminalSnapshot,
            allocator,
            object,
            "terminals",
        ),
        .browsers = try decodeSnapshotArray(
            BrowserSnapshot,
            allocator,
            object,
            "browsers",
        ),
        .clients = try decodeSnapshotArray(
            ClientSnapshot,
            allocator,
            object,
            "clients",
        ),
        .notifications = try decodeSnapshotArray(
            NotificationSnapshot,
            allocator,
            object,
            "notifications",
        ),
        .agents = try decodeSnapshotArray(
            AgentSnapshot,
            allocator,
            object,
            "agents",
        ),
        .frontend_projections = try decodeSnapshotArray(
            FrontendProjectionSnapshot,
            allocator,
            object,
            "frontend_projections",
        ),
        .sidebar_views = try decodeSnapshotArray(
            SidebarViewSnapshot,
            allocator,
            object,
            "sidebar_views",
        ),
        .cursor = try parseStrictCursor(
            object.get("cursor") orelse return error.MissingField,
        ),
        .extra = try optionalExtra(object),
    };
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

fn decodeTypedArenaList(
    comptime Snapshot: type,
    allocator: std.mem.Allocator,
    result: OwnedResult,
    legacy_field: []const u8,
) !OwnedDecodedList(Snapshot) {
    var owned_result = result;
    errdefer owned_result.deinit();
    var decoded = std.heap.ArenaAllocator.init(allocator);
    errdefer decoded.deinit();
    const values = try listItems(owned_result.value, legacy_field);
    const items = try decoded.allocator().alloc(Snapshot, values.len);
    for (values, 0..) |value, index| {
        items[index] = try decodeArenaSnapshot(
            Snapshot,
            decoded.allocator(),
            value,
        );
    }
    const list = OwnedDecodedList(Snapshot){
        .owned = owned_result.owned,
        .decoded = decoded,
        .items = items,
    };
    owned_result = undefined;
    decoded = undefined;
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
    else if (comptime Result == TerminalWaitExitResult)
        try decodeTerminalWaitExitResult(owned_result.value)
    else if (comptime Result == TerminalCopyResult)
        try decodeTerminalCopyResult(owned_result.value)
    else if (comptime Result == PaneNeighborResult)
        try decodePaneNeighborResult(owned_result.value)
    else if (comptime Result == CreationResolution)
        try decodeCreationResolution(owned_result.value)
    else if (comptime Result == PairingResolutionResult)
        try decodePairingResolutionResult(owned_result.value)
    else if (comptime Result == ViewerResizeResult)
        try decodeViewerResizeResult(owned_result.value)
    else if (comptime Result == BrowserViewerResizeResult)
        try decodeBrowserViewerResizeResult(owned_result.value)
    else if (comptime Result == ViewerReleaseResult)
        try decodeViewerReleaseResult(owned_result.value)
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
    else if (comptime Result == TerminalSnapshot)
        try decodeTerminalSnapshot(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == ResourceSnapshot)
        try decodeResourceSnapshot(
            decoded_arena.allocator(),
            owned_result.value,
        )
    else if (comptime Result == ReloadConfigResult)
        try decodeReloadConfigResult(
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
    } else if (comptime Value == ShutdownResult)
        try decodeShutdownResult(raw_result.value)
    else if (comptime Value == TerminalDefaultsSnapshot)
        try decodeTerminalDefaultsSnapshot(raw_result.value)
    else if (comptime Value == PairingResolutionResult)
        try decodePairingResolutionResult(raw_result.value)
    else
        try decodeTypedSnapshot(Value, raw_result.value);
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
    else if (comptime Value == TerminalSnapshot)
        try decodeTerminalSnapshot(
            decoded_arena.allocator(),
            raw_result.value,
        )
    else if (comptime Value == ReloadConfigResult)
        try decodeReloadConfigResult(
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

pub fn BasicResourceSnapshot(comptime Id: type) type {
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
) !BasicResourceSnapshot(Id) {
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
    const snapshot = BasicResourceSnapshot(Id){
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
    if (std.mem.eql(u8, scope, "screen")) return OwnedScreenSnapshot;
    if (std.mem.eql(u8, scope, "pane")) return OwnedPaneSnapshot;
    if (std.mem.eql(u8, scope, "tab")) return OwnedTabSnapshot;
    if (std.mem.eql(u8, scope, "terminal")) {
        return OwnedTerminalSnapshot;
    }
    if (std.mem.eql(u8, scope, "browser")) return OwnedBrowserSnapshot;
    if (std.mem.eql(u8, scope, "client")) return OwnedClientSnapshot;
    if (std.mem.eql(u8, scope, "frontend_projection")) {
        return OwnedFrontendProjectionSnapshot;
    }
    if (std.mem.eql(u8, scope, "sidebar_view")) {
        return OwnedValue(SidebarViewSnapshot);
    }
    return BasicResourceSnapshot(Id);
}

fn decodeRefreshResult(
    comptime Id: type,
    comptime scope: []const u8,
    allocator: std.mem.Allocator,
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
    if (comptime std.mem.eql(u8, scope, "screen")) {
        return decodeOwnedAllocatedResult(
            ScreenSnapshot,
            allocator,
            result,
        );
    }
    if (comptime std.mem.eql(u8, scope, "pane")) {
        return decodeOwnedTypedSnapshot(PaneSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "tab")) {
        return decodeOwnedTypedSnapshot(TabSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "terminal")) {
        return decodeOwnedAllocatedResult(
            TerminalSnapshot,
            allocator,
            result,
        );
    }
    if (comptime std.mem.eql(u8, scope, "browser")) {
        return decodeOwnedTypedSnapshot(BrowserSnapshot, result);
    }
    if (comptime std.mem.eql(u8, scope, "client")) {
        return decodeOwnedAllocatedResult(
            ClientSnapshot,
            allocator,
            result,
        );
    }
    if (comptime std.mem.eql(u8, scope, "frontend_projection")) {
        return decodeOwnedTypedSnapshot(
            FrontendProjectionSnapshot,
            result,
        );
    }
    if (comptime std.mem.eql(u8, scope, "sidebar_view")) {
        return decodeOwnedTypedSnapshot(SidebarViewSnapshot, result);
    }
    return decodeSnapshot(Id, fallback_id, result);
}

fn RenameMutationResult(comptime scope: []const u8) type {
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
    if (std.mem.eql(u8, scope, "session")) return ShutdownMutationResult;
    return EmptyMutationResult;
}

fn decodeCloseMutation(
    comptime scope: []const u8,
    result: MutationResult,
) !CloseMutationResult(scope) {
    if (comptime std.mem.eql(u8, scope, "session")) {
        return decodeTypedMutation(ShutdownResult, result);
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

/// Private implementation shared by capability-specific public facades.
fn HandleImpl(
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

        fn initScoped(
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
            if (comptime !std.mem.eql(u8, scope, "session") and
                !std.mem.eql(u8, scope, "tab"))
            {
                @compileError(
                    "terminal() is available only on Session and Tab",
                );
            }
            var route = self.target.ancestors;
            if (comptime std.mem.eql(u8, scope, "session")) {
                route.session = self.target.selector;
            } else {
                route.tab = self.target.selector;
            }
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

        pub fn connectedClient(
            self: Self,
            child: anytype,
        ) ConnectedClient {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                @compileError(
                    "connectedClient() is available only on Session",
                );
            }
            var route = self.target.ancestors;
            route.session = self.target.selector;
            return ConnectedClient.initScoped(self.client, child, route);
        }

        pub fn pairingRequest(
            self: Self,
            child: anytype,
        ) PairingRequest {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                @compileError(
                    "pairingRequest() is available only on Session",
                );
            }
            var route = self.target.ancestors;
            route.session = self.target.selector;
            return PairingRequest.initScoped(self.client, child, route);
        }

        pub fn frontendProjection(
            self: Self,
            child: anytype,
        ) FrontendProjection {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                @compileError(
                    "frontendProjection() is available only on Session",
                );
            }
            var route = self.target.ancestors;
            route.session = self.target.selector;
            return FrontendProjection.initScoped(
                self.client,
                child,
                route,
            );
        }

        pub fn sidebarView(
            self: Self,
            child: anytype,
        ) SidebarView {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                @compileError(
                    "sidebarView() is available only on Session",
                );
            }
            var route = self.target.ancestors;
            route.session = self.target.selector;
            return SidebarView.initScoped(self.client, child, route);
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
                self.client.allocator,
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

        pub fn listScreens(self: Self) !ScreenList {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedArenaList(
                ScreenSnapshot,
                self.client.allocator,
                try self.read(.screen_list, null),
                "screens",
            );
        }

        pub fn listPanes(self: Self) !PaneList {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedList(
                PaneSnapshot,
                self.client.allocator,
                try self.read(.pane_list, null),
                "panes",
            );
        }

        pub fn listTabs(self: Self) !TabList {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedList(
                TabSnapshot,
                self.client.allocator,
                try self.read(.tab_list, null),
                "tabs",
            );
        }

        pub fn listTerminals(self: Self) !TerminalList {
            if (comptime !std.mem.eql(u8, scope, "session") and
                !std.mem.eql(u8, scope, "workspace") and
                !std.mem.eql(u8, scope, "screen") and
                !std.mem.eql(u8, scope, "pane") and
                !std.mem.eql(u8, scope, "tab"))
            {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedArenaList(
                TerminalSnapshot,
                self.client.allocator,
                try self.read(.terminal_list, null),
                "terminals",
            );
        }

        pub fn listBrowsers(self: Self) !BrowserList {
            if (comptime !std.mem.eql(u8, scope, "session") and
                !std.mem.eql(u8, scope, "workspace") and
                !std.mem.eql(u8, scope, "screen") and
                !std.mem.eql(u8, scope, "pane") and
                !std.mem.eql(u8, scope, "tab"))
            {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedList(
                BrowserSnapshot,
                self.client.allocator,
                try self.read(.browser_list, null),
                "browsers",
            );
        }

        pub fn listClients(self: Self) !ClientList {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedArenaList(
                ClientSnapshot,
                self.client.allocator,
                try self.read(.client_list, null),
                "clients",
            );
        }

        pub fn listPairingRequests(self: Self) !PairingRequestList {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedList(
                PairingRequestSnapshot,
                self.client.allocator,
                try self.read(.pairing_request_list, null),
                "pairing_requests",
            );
        }

        pub fn listNotifications(
            self: Self,
            options: NotificationListOptions,
        ) !NotificationList {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            if (options.limit) |limit| {
                if (limit == 0 or limit > 1000) {
                    return error.InvalidNotificationLimit;
                }
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (options.limit) |limit| {
                try params.putValue("limit", .{ .integer = limit });
            }
            return decodeTypedList(
                NotificationSnapshot,
                self.client.allocator,
                try self.client.read(
                    .notification_list,
                    params.asValue(),
                ),
                "notifications",
            );
        }

        pub fn listAgents(
            self: Self,
            options: AgentListOptions,
        ) !AgentList {
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
            if (options.terminal_id) |terminal_id| {
                try params.putString(
                    "terminal_id",
                    terminal_id.slice(),
                );
            }
            if (options.state) |state| {
                try params.putString("state", state.wireName());
            }
            return decodeTypedList(
                AgentSnapshot,
                self.client.allocator,
                try self.client.read(.agent_list, params.asValue()),
                "agents",
            );
        }

        pub fn createNotification(
            self: Self,
            notification_options: NotificationCreateOptions,
            mutation: MutationOptions,
        ) !NotificationMutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            if (notification_options.title.len == 0) {
                return error.InvalidNotificationTitle;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("title", notification_options.title);
            try params.putString("body", notification_options.body);
            try params.putString(
                "level",
                notification_options.level.wireName(),
            );
            if (notification_options.terminal_id) |terminal_id| {
                try params.putString("terminal_id", terminal_id.slice());
            }
            return decodeTypedMutation(
                NotificationSnapshot,
                try self.client.mutate(
                    .notification_create,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn reportAgent(
            self: Self,
            report: AgentReportOptions,
            mutation: MutationOptions,
        ) !AgentMutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            switch (report.source) {
                .hook, .socket => {},
                .detected, .unknown => {
                    return error.InvalidReportAgentSource;
                },
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString(
                "terminal_id",
                report.terminal_id.slice(),
            );
            try params.putString("state", report.state.wireName());
            try params.putString("source", report.source.wireName());
            if (report.source_session) |source_session| {
                try params.putString(
                    "source_session",
                    source_session,
                );
            }
            return decodeTypedMutation(
                AgentSnapshot,
                try self.client.mutate(
                    .agent_report,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn ensureSidebarView(
            self: Self,
            ensure: SidebarEnsureOptions,
            mutation: MutationOptions,
        ) !SidebarViewMutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            if (ensure.cols == 0 or ensure.rows == 0) {
                return error.InvalidTerminalSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue("cols", .{ .integer = ensure.cols });
            try params.putValue("rows", .{ .integer = ensure.rows });
            if (ensure.relaunch) {
                try params.putValue("relaunch", .{ .bool = true });
            }
            return decodeTypedMutation(
                SidebarViewSnapshot,
                try self.client.mutate(
                    .sidebar_view_ensure,
                    params.asValue(),
                    mutation,
                ),
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

        pub fn openSession(
            self: Self,
            selection: anytype,
            mutation: MutationOptions,
        ) !SessionMutationResult {
            if (comptime !std.mem.eql(u8, scope, "machine")) {
                return error.UnsupportedHandleOperation;
            }
            const session_selector = selectorValue(SessionId, selection);
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            const encoded = try session_selector.formatAlloc(
                params.arena.allocator(),
            );
            try params.putString("session", encoded);
            return decodeTypedMutation(
                SessionSnapshot,
                try self.client.mutate(
                    .session_open,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn fullSnapshot(self: Self) !OwnedResourceSnapshot {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeOwnedAllocatedResult(
                ResourceSnapshot,
                self.client.allocator,
                try self.read(.session_snapshot, null),
            );
        }

        pub fn resolveCreation(
            self: Self,
            correlation_key: []const u8,
        ) !OwnedCreationResolution {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            if (correlation_key.len == 0 or correlation_key.len > 128) {
                return error.InvalidCorrelationKey;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("correlation_key", correlation_key);
            return decodeOwnedSimpleResult(
                CreationResolution,
                try self.client.read(
                    .session_creation_resolve,
                    params.asValue(),
                ),
            );
        }

        pub fn shutdown(
            self: Self,
            force: ?bool,
            mutation: MutationOptions,
        ) !ShutdownMutationResult {
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
            if (force) |value| {
                try params.putValue("force", .{ .bool = value });
            }
            return decodeTypedMutation(
                ShutdownResult,
                try self.client.mutate(
                    .session_shutdown,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn reloadConfig(
            self: Self,
            mutation: MutationOptions,
        ) !ReloadConfigMutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedAllocatedMutation(
                ReloadConfigResult,
                self.client.allocator,
                try self.mutate(
                    .session_reload_config,
                    null,
                    mutation,
                ),
            );
        }

        pub fn updateTerminalDefaults(
            self: Self,
            update: TerminalDefaultsUpdate,
            mutation: MutationOptions,
        ) !TerminalDefaultsMutationResult {
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
            try encodeTerminalDefaults(Id, &params, update);
            return decodeTypedMutation(
                TerminalDefaultsSnapshot,
                try self.client.mutate(
                    .session_terminal_defaults_update,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn setWindowTitle(
            self: Self,
            title: []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            try params.putString("title", title);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .session_window_title_set,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn clearWindowTitle(
            self: Self,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "session")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                EmptyResult,
                try self.mutate(
                    .session_window_title_clear,
                    null,
                    mutation,
                ),
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

        pub fn moveWorkspace(
            self: Self,
            index: u32,
            mutation: MutationOptions,
        ) !WorkspaceMutationResult {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue("index", .{ .integer = index });
            return decodeTypedMutation(
                WorkspaceSnapshot,
                try self.client.mutate(
                    .workspace_move,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn focusWorkspace(
            self: Self,
            mutation: MutationOptions,
        ) !WorkspaceMutationResult {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                WorkspaceSnapshot,
                try self.mutate(.workspace_focus, null, mutation),
            );
        }

        pub fn applyLayout(
            self: Self,
            document: LayoutDocument,
            mutation: MutationOptions,
        ) !WorkspaceMutationResult {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
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
                "layout",
                try encodeLayoutDocument(
                    params.arena.allocator(),
                    document,
                ),
            );
            return decodeTypedMutation(
                WorkspaceSnapshot,
                try self.client.mutate(
                    .workspace_layout_apply,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn createScreen(
            self: Self,
            create: CreateScreenOptions,
            mutation: MutationOptions,
        ) !CreatedPathMutationResult {
            if (comptime !std.mem.eql(u8, scope, "workspace")) {
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
            try encodeCorrelationKey(
                Id,
                &params,
                create.correlation_key,
            );
            return decodeTypedMutation(
                CreatedPath,
                try self.client.mutate(
                    .screen_create,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn focusScreen(
            self: Self,
            mutation: MutationOptions,
        ) !ScreenMutationResult {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedAllocatedMutation(
                ScreenSnapshot,
                self.client.allocator,
                try self.mutate(.screen_focus, null, mutation),
            );
        }

        pub fn exportLayout(
            self: Self,
        ) !OwnedLayoutDocument {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                return error.UnsupportedHandleOperation;
            }
            var result = try self.read(.screen_layout_export, null);
            errdefer result.deinit();
            var decoded = std.heap.ArenaAllocator.init(
                self.client.allocator,
            );
            errdefer decoded.deinit();
            const document = try decodeLayoutDocument(
                decoded.allocator(),
                result.value,
            );
            const owned = OwnedLayoutDocument{
                .owned = result.owned,
                .decoded = decoded,
                .value = document,
            };
            result = undefined;
            decoded = undefined;
            return owned;
        }

        pub fn undoLayout(
            self: Self,
            options: UndoLayoutOptions,
            mutation: MutationOptions,
        ) !ScreenMutationResult {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                return error.UnsupportedHandleOperation;
            }
            if (options.confirmation_token) |token| {
                if (token.len == 0 or token.len > 128) {
                    return error.InvalidConfirmationToken;
                }
            } else if (options.confirm_close) {
                return error.MissingConfirmationToken;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (options.confirm_close) {
                try params.putValue(
                    "confirm_close",
                    .{ .bool = true },
                );
            }
            if (options.confirmation_token) |token| {
                try params.putString("confirmation_token", token);
            }
            return decodeTypedAllocatedMutation(
                ScreenSnapshot,
                self.client.allocator,
                try self.client.mutate(
                    .screen_layout_undo,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn createPane(
            self: Self,
            create: CreatePaneOptions,
            mutation: MutationOptions,
        ) !CreatedPathMutationResult {
            if (comptime !std.mem.eql(u8, scope, "screen")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (create.cwd) |cwd| try params.putString("cwd", cwd);
            try encodeTerminalSize(
                Id,
                &params,
                create.cols,
                create.rows,
            );
            try encodeCorrelationKey(
                Id,
                &params,
                create.correlation_key,
            );
            return decodeTypedMutation(
                CreatedPath,
                try self.client.mutate(
                    .pane_create,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn splitPane(
            self: Self,
            split: SplitOptions,
            mutation: MutationOptions,
        ) !CreatedPathMutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            if (split.ratio) |ratio| {
                if (!std.math.isFinite(ratio) or
                    ratio <= 0 or ratio >= 1)
                {
                    return error.InvalidSplitRatio;
                }
            }
            if (split.viewport_width) |width| {
                if (std.meta.activeTag(split.direction) != .right or
                    !std.math.isFinite(width) or
                    width < 0.1 or width > 1.0)
                {
                    return error.InvalidViewportWidth;
                }
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString(
                "direction",
                split.direction.wireName(),
            );
            if (split.ratio) |ratio| {
                try params.putValue("ratio", .{ .float = ratio });
            }
            if (split.viewport_width) |width| {
                try params.putValue("viewport_width", .{ .float = width });
            }
            if (split.cwd) |cwd| try params.putString("cwd", cwd);
            try encodeTerminalSize(
                Id,
                &params,
                split.cols,
                split.rows,
            );
            try encodeCorrelationKey(
                Id,
                &params,
                split.correlation_key,
            );
            return decodeTypedMutation(
                CreatedPath,
                try self.client.mutate(
                    .pane_split,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn focusPane(
            self: Self,
            mutation: MutationOptions,
        ) !PaneMutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                PaneSnapshot,
                try self.mutate(.pane_focus, null, mutation),
            );
        }

        pub fn focusDirection(
            self: Self,
            direction: Direction,
            mutation: MutationOptions,
        ) !PaneMutationResult {
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
            try params.putString(
                "direction",
                direction.wireName(),
            );
            return decodeTypedMutation(
                PaneSnapshot,
                try self.client.mutate(
                    .pane_focus_direction,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn neighbor(
            self: Self,
            direction: Direction,
        ) !OwnedPaneNeighborResult {
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
            try params.putString(
                "direction",
                direction.wireName(),
            );
            return decodeOwnedSimpleResult(
                PaneNeighborResult,
                try self.client.read(
                    .pane_neighbor_get,
                    params.asValue(),
                ),
            );
        }

        pub fn swapPane(
            self: Self,
            destination: MoveDestination,
            mutation: MutationOptions,
        ) !PaneMutationResult {
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
            try params.putString(
                "other_workspace",
                destination.workspace.slice(),
            );
            try params.putString(
                "other_screen",
                destination.screen.slice(),
            );
            try params.putString(
                "other_pane",
                destination.pane.slice(),
            );
            return decodeTypedMutation(
                PaneSnapshot,
                try self.client.mutate(
                    .pane_swap,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn zoomPane(
            self: Self,
            enabled: ?bool,
            mutation: MutationOptions,
        ) !PaneMutationResult {
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
            if (enabled) |value| {
                try params.putValue("enabled", .{ .bool = value });
            }
            return decodeTypedMutation(
                PaneSnapshot,
                try self.client.mutate(
                    .pane_zoom,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn setSplitRatio(
            self: Self,
            split_id: SplitId,
            ratio: f64,
            mutation: MutationOptions,
        ) !PaneMutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            if (!std.math.isFinite(ratio) or ratio <= 0 or ratio >= 1) {
                return error.InvalidSplitRatio;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("split_id", split_id.slice());
            try params.putValue("ratio", .{ .float = ratio });
            return decodeTypedMutation(
                PaneSnapshot,
                try self.client.mutate(
                    .pane_split_ratio_set,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn setViewportWidth(
            self: Self,
            columns: u16,
            mutation: MutationOptions,
        ) !PaneMutationResult {
            if (comptime !std.mem.eql(u8, scope, "pane")) {
                return error.UnsupportedHandleOperation;
            }
            if (columns == 0) return error.InvalidViewportWidth;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue("columns", .{ .integer = columns });
            return decodeTypedMutation(
                PaneSnapshot,
                try self.client.mutate(
                    .pane_viewport_width_set,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn focusTab(
            self: Self,
            mutation: MutationOptions,
        ) !TabMutationResult {
            if (comptime !std.mem.eql(u8, scope, "tab")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                TabSnapshot,
                try self.mutate(.tab_focus, null, mutation),
            );
        }

        pub fn moveTab(
            self: Self,
            destination: MoveDestination,
            mutation: MutationOptions,
        ) !TabMutationResult {
            if (comptime !std.mem.eql(u8, scope, "tab")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try encodeMoveDestination(Id, &params, destination);
            return decodeTypedMutation(
                TabSnapshot,
                try self.client.mutate(
                    .tab_move,
                    params.asValue(),
                    mutation,
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

        pub fn waitForExit(
            self: Self,
            timeout_ms: ?u64,
        ) !OwnedTerminalWaitExitResult {
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
            if (timeout_ms) |timeout| {
                const encoded = try std.fmt.allocPrint(
                    params.arena.allocator(),
                    "{d}",
                    .{timeout},
                );
                try params.putString("timeout_ms", encoded);
            }
            return decodeOwnedSimpleResult(
                TerminalWaitExitResult,
                try self.client.read(
                    .terminal_wait_exit,
                    params.asValue(),
                ),
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

        pub fn writeBytes(
            self: Self,
            bytes: []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            const encoded = try raw.encodeBase64Alloc(
                self.client.allocator,
                bytes,
            );
            defer self.client.allocator.free(encoded);
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("bytes_base64", encoded);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_input_write,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendKeys(
            self: Self,
            keys: []const []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (keys.len == 0) return error.EmptyKeySequence;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            const allocator = params.arena.allocator();
            var encoded = std.json.Array.init(allocator);
            for (keys) |key| {
                if (key.len == 0) return error.InvalidKey;
                try encoded.append(.{
                    .string = try allocator.dupe(u8, key),
                });
            }
            try params.putValue("keys", .{ .array = encoded });
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_input_keys,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendMouse(
            self: Self,
            mouse: TerminalMouseOptions,
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
            try params.putString("kind", mouse.kind.wireName());
            if (mouse.button) |button| {
                try params.putValue("button", .{ .integer = button });
            }
            if (mouse.row) |row| {
                try params.putValue("row", .{ .integer = row });
            }
            if (mouse.column) |column| {
                try params.putValue(
                    "column",
                    .{ .integer = column },
                );
            }
            if (mouse.delta_rows) |delta_rows| {
                try params.putValue(
                    "delta_rows",
                    .{ .integer = delta_rows },
                );
            }
            try encodeModifiers(Id, &params, mouse.modifiers);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_input_mouse,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn setInputFocus(
            self: Self,
            focused: bool,
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
            try params.putValue("focused", .{ .bool = focused });
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .terminal_input_focus,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn moveTerminal(
            self: Self,
            destination: MoveDestination,
            mutation: MutationOptions,
        ) !TerminalMutationResult {
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
            try encodeMoveDestination(Id, &params, destination);
            return decodeTypedAllocatedMutation(
                TerminalSnapshot,
                self.client.allocator,
                try self.client.mutate(
                    .terminal_move,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn projectTerminal(
            self: Self,
            options: TerminalProjectOptions,
            mutation: MutationOptions,
        ) !TabMutationResult {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (options.destination.index == null) {
                return error.MissingField;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try encodeMoveDestination(Id, &params, options.destination);
            if (options.name) |name| {
                try params.putString("name", name);
            }
            return decodeTypedMutation(
                TabSnapshot,
                try self.client.mutate(
                    .terminal_project,
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

        fn mutateBrowserSnapshot(
            self: Self,
            operation: Operation,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                BrowserSnapshot,
                try self.mutate(operation, null, mutation),
            );
        }

        pub fn browserBack(
            self: Self,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
            return self.mutateBrowserSnapshot(.browser_back, mutation);
        }

        pub fn browserForward(
            self: Self,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
            return self.mutateBrowserSnapshot(
                .browser_forward,
                mutation,
            );
        }

        pub fn reloadBrowser(
            self: Self,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
            return self.mutateBrowserSnapshot(.browser_reload, mutation);
        }

        pub fn activateBrowser(
            self: Self,
            mutation: MutationOptions,
        ) !BrowserMutationResult {
            return self.mutateBrowserSnapshot(
                .browser_activate,
                mutation,
            );
        }

        pub fn sendBrowserKey(
            self: Self,
            key: BrowserKeyOptions,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            if (key.key.len == 0) return error.InvalidKey;
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("kind", key.kind.wireName());
            try params.putString("key", key.key);
            try encodeModifiers(Id, &params, key.modifiers);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .browser_input_key,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendBrowserText(
            self: Self,
            text: []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            try params.putString("text", text);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .browser_input_text,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendBrowserMouse(
            self: Self,
            mouse: BrowserMouseOptions,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
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
            try params.putString("kind", mouse.kind.wireName());
            try params.putValue("x_px", .{ .integer = mouse.x_px });
            try params.putValue("y_px", .{ .integer = mouse.y_px });
            try params.putDecimal(
                "pointer_frame_seq",
                mouse.pointer_frame_seq,
            );
            if (mouse.button) |button| {
                try params.putValue("button", .{ .integer = button });
            }
            if (mouse.click_count) |click_count| {
                try params.putValue(
                    "click_count",
                    .{ .integer = click_count },
                );
            }
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .browser_input_mouse,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendBrowserWheel(
            self: Self,
            wheel: BrowserWheelOptions,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            if (!std.math.isFinite(wheel.delta_x) or
                !std.math.isFinite(wheel.delta_y))
            {
                return error.InvalidWheelDelta;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue(
                "delta_x",
                .{ .float = wheel.delta_x },
            );
            try params.putValue(
                "delta_y",
                .{ .float = wheel.delta_y },
            );
            try params.putDecimal(
                "pointer_frame_seq",
                wheel.pointer_frame_seq,
            );
            if (wheel.x_px) |x| {
                try params.putValue("x_px", .{ .integer = x });
            }
            if (wheel.y_px) |y| {
                try params.putValue("y_px", .{ .integer = y });
            }
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .browser_input_wheel,
                    params.asValue(),
                    mutation,
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

        pub fn setSizing(
            self: Self,
            terminal_id: TerminalId,
            enabled: bool,
            exclusive: ?bool,
        ) !OwnedClientSnapshot {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("terminal", terminal_id.slice());
            try params.putValue("enabled", .{ .bool = enabled });
            if (exclusive) |value| {
                try params.putValue(
                    "exclusive",
                    .{ .bool = value },
                );
            }
            return decodeOwnedAllocatedResult(
                ClientSnapshot,
                self.client.allocator,
                try self.client.control(
                    .client_sizing_set,
                    params.asValue(),
                ),
            );
        }

        pub fn releaseSizing(
            self: Self,
            terminal_id: TerminalId,
        ) !OwnedClientSnapshot {
            if (comptime !std.mem.eql(u8, scope, "client")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("terminal", terminal_id.slice());
            return decodeOwnedAllocatedResult(
                ClientSnapshot,
                self.client.allocator,
                try self.client.control(
                    .client_sizing_release,
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
            try encodeCorrelationKey(
                Id,
                &params,
                create.correlation_key,
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
            return self.eventsFrom(null);
        }

        pub fn eventsFrom(
            self: Self,
            cursor: ?Cursor,
        ) !SessionEventStream {
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
            if (cursor) |value| {
                const allocator = params.arena.allocator();
                var encoded = raw.wire.Object.init(allocator);
                try encoded.put(
                    "generation",
                    .{ .string = try allocator.dupe(
                        u8,
                        value.generation,
                    ) },
                );
                try encoded.put(
                    "revision",
                    .{ .string = try std.fmt.allocPrint(
                        allocator,
                        "{d}",
                        .{value.revision},
                    ) },
                );
                try params.putValue("cursor", .{ .object = encoded });
            }
            return self.client.openSessionEvents(params.asValue());
        }

        pub fn journal(
            self: Self,
            options: SessionJournalOptions,
        ) !SessionJournalStream {
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
            try encodeSessionJournalOptions(Id, &params, options);
            return self.client.openSessionJournal(params.asValue());
        }

        pub fn attachTerminal(self: Self) !TerminalAttachmentStream {
            return self.attachTerminalWith(.{});
        }

        pub fn attachTerminalWith(
            self: Self,
            attach_options: TerminalAttachOptions,
        ) !TerminalAttachmentStream {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if ((attach_options.cols == null) !=
                (attach_options.rows == null))
            {
                return error.IncompleteTerminalSize;
            }
            if ((attach_options.cols orelse 1) == 0 or
                (attach_options.rows orelse 1) == 0)
            {
                return error.InvalidTerminalSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (attach_options.read_only) |read_only| {
                try params.putValue(
                    "read_only",
                    .{ .bool = read_only },
                );
            }
            if (attach_options.cols) |cols| {
                try params.putValue("cols", .{ .integer = cols });
                try params.putValue(
                    "rows",
                    .{ .integer = attach_options.rows.? },
                );
            }
            return self.client.openTerminalAttachment(params.asValue());
        }

        pub fn attachBrowser(self: Self) !BrowserAttachmentStream {
            return self.attachBrowserWith(.{});
        }

        pub fn attachBrowserWith(
            self: Self,
            attach_options: BrowserAttachOptions,
        ) !BrowserAttachmentStream {
            if (comptime !std.mem.eql(u8, scope, "browser")) {
                return error.UnsupportedHandleOperation;
            }
            if ((attach_options.width_px == null) !=
                (attach_options.height_px == null))
            {
                return error.IncompleteBrowserSize;
            }
            if ((attach_options.width_px orelse 1) == 0 or
                (attach_options.height_px orelse 1) == 0)
            {
                return error.InvalidBrowserSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (attach_options.width_px) |width_px| {
                try params.putValue(
                    "width_px",
                    .{ .integer = width_px },
                );
                try params.putValue(
                    "height_px",
                    .{ .integer = attach_options.height_px.? },
                );
            }
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

        pub fn resolvePairing(
            self: Self,
            decision: PairingDecision,
            mutation: MutationOptions,
        ) !PairingResolutionMutationResult {
            if (comptime !std.mem.eql(u8, scope, "pairing_request")) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("decision", @tagName(decision));
            return decodeTypedMutation(
                PairingResolutionResult,
                try self.client.mutate(
                    .pairing_request_resolve,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn putProjection(
            self: Self,
            projection: ProjectionPutOptions,
            mutation: MutationOptions,
        ) !FrontendProjectionMutationResult {
            if (comptime !std.mem.eql(
                u8,
                scope,
                "frontend_projection",
            )) {
                return error.UnsupportedHandleOperation;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (projection.frontend_id.len < 1 or projection.frontend_id.len > 128 or
                projection.window_id.len < 1 or projection.window_id.len > 128 or
                projection.generation.len < 1 or projection.generation.len > 128)
            {
                return error.InvalidProjectionIdentity;
            }
            try params.putString("frontend_id", projection.frontend_id);
            try params.putString("window_id", projection.window_id);
            try params.putString("generation", projection.generation);
            try params.putValue("projection", projection.projection);
            if (projection.expected_projection_revision) |revision| {
                try params.putDecimal(
                    "expected_projection_revision",
                    revision,
                );
            }
            return decodeTypedMutation(
                FrontendProjectionSnapshot,
                try self.client.mutate(
                    .frontend_projection_put,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn sendSidebarInput(
            self: Self,
            bytes: []const u8,
            mutation: MutationOptions,
        ) !EmptyMutationResult {
            if (comptime !std.mem.eql(u8, scope, "sidebar_view")) {
                return error.UnsupportedHandleOperation;
            }
            const encoded = try raw.encodeBase64Alloc(
                self.client.allocator,
                bytes,
            );
            defer self.client.allocator.free(encoded);
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putString("data_base64", encoded);
            return decodeTypedMutation(
                EmptyResult,
                try self.client.mutate(
                    .sidebar_view_input,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn resizeSidebar(
            self: Self,
            cols: u16,
            rows: u16,
            mutation: MutationOptions,
        ) !SidebarViewMutationResult {
            if (comptime !std.mem.eql(u8, scope, "sidebar_view")) {
                return error.UnsupportedHandleOperation;
            }
            if (cols == 0 or rows == 0) {
                return error.InvalidTerminalSize;
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            try params.putValue("cols", .{ .integer = cols });
            try params.putValue("rows", .{ .integer = rows });
            return decodeTypedMutation(
                SidebarViewSnapshot,
                try self.client.mutate(
                    .sidebar_view_resize,
                    params.asValue(),
                    mutation,
                ),
            );
        }

        pub fn reloadSidebar(
            self: Self,
            mutation: MutationOptions,
        ) !SidebarViewMutationResult {
            if (comptime !std.mem.eql(u8, scope, "sidebar_view")) {
                return error.UnsupportedHandleOperation;
            }
            return decodeTypedMutation(
                SidebarViewSnapshot,
                try self.mutate(
                    .sidebar_view_reload,
                    null,
                    mutation,
                ),
            );
        }

        pub fn rendererGrant(self: Self) !*RendererGrant {
            return self.rendererGrantWith(.{});
        }

        pub fn rendererGrantWith(
            self: Self,
            request: RendererGrantRequest,
        ) !*RendererGrant {
            if (comptime !std.mem.eql(u8, scope, "terminal")) {
                return error.UnsupportedHandleOperation;
            }
            if (request.ttl_ms) |ttl_ms| {
                if (ttl_ms == 0 or ttl_ms > 60_000) {
                    return error.InvalidRendererGrantTtl;
                }
            }
            var params = try Params(Id).init(
                self.client.allocator,
                scope,
                &self.target,
                null,
            );
            defer params.deinit();
            if (request.ttl_ms) |ttl_ms| {
                try params.putValue(
                    "ttl_ms",
                    .{ .integer = ttl_ms },
                );
            }
            var result = try self.client.control(
                .terminal_renderer_grant_create,
                params.asValue(),
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
            const ttl_ms = try objectUnsigned(
                u32,
                object,
                "ttl_ms",
                1,
            );
            if (ttl_ms > 60_000) {
                return error.InvalidRendererGrantTtl;
            }
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

fn initHandleFacade(
    comptime Facade: type,
    comptime Id: type,
    client: *Client,
    selection: anytype,
    ancestors: HandleRoute,
) Facade {
    return .{
        .client = client,
        .target = .{
            .selector = selectorValue(Id, selection),
            .ancestors = ancestors,
        },
    };
}

fn handleFacadeImpl(comptime Impl: type, facade: anytype) Impl {
    return .{
        .client = facade.client,
        .target = facade.target,
    };
}

pub const Machine = struct {
    const Self = @This();
    const Impl = HandleImpl(MachineId, "machine", .{
        .get = .machine_get,
    });

    client: *Client,
    target: ScopedSelector(MachineId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            MachineId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            MachineId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(MachineId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?MachineId {
        return self.impl().id();
    }

    pub fn session(self: Self, child: anytype) Session {
        return self.impl().session(child);
    }

    pub fn refresh(self: Self) !OwnedMachineSnapshot {
        return self.impl().refresh();
    }

    pub fn listSessions(self: Self) !SessionList {
        return self.impl().listSessions();
    }

    pub fn openSession(
        self: Self,
        selection: anytype,
        mutation: MutationOptions,
    ) !SessionMutationResult {
        return self.impl().openSession(selection, mutation);
    }
};

pub const Session = struct {
    const Self = @This();
    const Impl = HandleImpl(SessionId, "session", .{
        .get = .session_get,
        .close = .session_shutdown,
    });

    client: *Client,
    target: ScopedSelector(SessionId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            SessionId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            SessionId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(SessionId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?SessionId {
        return self.impl().id();
    }

    pub fn workspace(self: Self, child: anytype) Workspace {
        return self.impl().workspace(child);
    }

    pub fn terminal(self: Self, child: anytype) Terminal {
        return self.impl().terminal(child);
    }

    pub fn connectedClient(
        self: Self,
        child: anytype,
    ) ConnectedClient {
        return self.impl().connectedClient(child);
    }

    pub fn pairingRequest(
        self: Self,
        child: anytype,
    ) PairingRequest {
        return self.impl().pairingRequest(child);
    }

    pub fn frontendProjection(
        self: Self,
        child: anytype,
    ) FrontendProjection {
        return self.impl().frontendProjection(child);
    }

    pub fn sidebarView(
        self: Self,
        child: anytype,
    ) SidebarView {
        return self.impl().sidebarView(child);
    }

    pub fn refresh(self: Self) !OwnedSessionSnapshot {
        return self.impl().refresh();
    }

    pub fn listWorkspaces(self: Self) !WorkspaceList {
        return self.impl().listWorkspaces();
    }

    pub fn listScreens(self: Self) !ScreenList {
        return self.impl().listScreens();
    }

    pub fn listPanes(self: Self) !PaneList {
        return self.impl().listPanes();
    }

    pub fn listTerminals(self: Self) !TerminalList {
        return self.impl().listTerminals();
    }

    pub fn listBrowsers(self: Self) !BrowserList {
        return self.impl().listBrowsers();
    }

    pub fn listClients(self: Self) !ClientList {
        return self.impl().listClients();
    }

    pub fn listPairingRequests(self: Self) !PairingRequestList {
        return self.impl().listPairingRequests();
    }

    pub fn listNotifications(
        self: Self,
        options: NotificationListOptions,
    ) !NotificationList {
        return self.impl().listNotifications(options);
    }

    pub fn listAgents(
        self: Self,
        options: AgentListOptions,
    ) !AgentList {
        return self.impl().listAgents(options);
    }

    pub fn createNotification(
        self: Self,
        options: NotificationCreateOptions,
        mutation: MutationOptions,
    ) !NotificationMutationResult {
        return self.impl().createNotification(options, mutation);
    }

    pub fn reportAgent(
        self: Self,
        report: AgentReportOptions,
        mutation: MutationOptions,
    ) !AgentMutationResult {
        return self.impl().reportAgent(report, mutation);
    }

    pub fn ensureSidebarView(
        self: Self,
        ensure: SidebarEnsureOptions,
        mutation: MutationOptions,
    ) !SidebarViewMutationResult {
        return self.impl().ensureSidebarView(ensure, mutation);
    }

    pub fn ping(self: Self) !OwnedPingResult {
        return self.impl().ping();
    }

    pub fn fullSnapshot(self: Self) !OwnedResourceSnapshot {
        return self.impl().fullSnapshot();
    }

    pub fn resolveCreation(
        self: Self,
        correlation_key: []const u8,
    ) !OwnedCreationResolution {
        return self.impl().resolveCreation(correlation_key);
    }

    pub fn shutdown(
        self: Self,
        force: ?bool,
        mutation: MutationOptions,
    ) !ShutdownMutationResult {
        return self.impl().shutdown(force, mutation);
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !ShutdownMutationResult {
        return self.impl().close(mutation);
    }

    pub fn reloadConfig(
        self: Self,
        mutation: MutationOptions,
    ) !ReloadConfigMutationResult {
        return self.impl().reloadConfig(mutation);
    }

    pub fn updateTerminalDefaults(
        self: Self,
        update: TerminalDefaultsUpdate,
        mutation: MutationOptions,
    ) !TerminalDefaultsMutationResult {
        return self.impl().updateTerminalDefaults(update, mutation);
    }

    pub fn setWindowTitle(
        self: Self,
        title: []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().setWindowTitle(title, mutation);
    }

    pub fn clearWindowTitle(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().clearWindowTitle(mutation);
    }

    pub fn createWorkspace(
        self: Self,
        create: CreateWorkspaceOptions,
        mutation: MutationOptions,
    ) !CreatedPathMutationResult {
        return self.impl().createWorkspace(create, mutation);
    }

    pub fn events(self: Self) !SessionEventStream {
        return self.impl().events();
    }

    pub fn eventsFrom(
        self: Self,
        cursor: ?Cursor,
    ) !SessionEventStream {
        return self.impl().eventsFrom(cursor);
    }

    pub fn journal(
        self: Self,
        options: SessionJournalOptions,
    ) !SessionJournalStream {
        return self.impl().journal(options);
    }
};

pub const Workspace = struct {
    const Self = @This();
    const Impl = HandleImpl(WorkspaceId, "workspace", .{
        .get = .workspace_get,
        .close = .workspace_close,
        .rename = .workspace_rename,
        .run = .workspace_run,
        .clear_name_with_null = false,
    });

    client: *Client,
    target: ScopedSelector(WorkspaceId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            WorkspaceId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            WorkspaceId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(WorkspaceId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?WorkspaceId {
        return self.impl().id();
    }

    pub fn screen(self: Self, child: anytype) Screen {
        return self.impl().screen(child);
    }

    pub fn refresh(self: Self) !OwnedWorkspaceSnapshot {
        return self.impl().refresh();
    }

    pub fn listScreens(self: Self) !ScreenList {
        return self.impl().listScreens();
    }

    pub fn listPanes(self: Self) !PaneList {
        return self.impl().listPanes();
    }

    pub fn listTerminals(self: Self) !TerminalList {
        return self.impl().listTerminals();
    }

    pub fn listBrowsers(self: Self) !BrowserList {
        return self.impl().listBrowsers();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn rename(
        self: Self,
        name: []const u8,
        mutation: MutationOptions,
    ) !WorkspaceMutationResult {
        return self.impl().rename(name, mutation);
    }

    pub fn clearName(
        self: Self,
        mutation: MutationOptions,
    ) !WorkspaceMutationResult {
        return self.impl().clearName(mutation);
    }

    pub fn moveWorkspace(
        self: Self,
        index: u32,
        mutation: MutationOptions,
    ) !WorkspaceMutationResult {
        return self.impl().moveWorkspace(index, mutation);
    }

    pub fn focusWorkspace(
        self: Self,
        mutation: MutationOptions,
    ) !WorkspaceMutationResult {
        return self.impl().focusWorkspace(mutation);
    }

    pub fn applyLayout(
        self: Self,
        document: LayoutDocument,
        mutation: MutationOptions,
    ) !WorkspaceMutationResult {
        return self.impl().applyLayout(document, mutation);
    }

    pub fn createScreen(
        self: Self,
        create: CreateScreenOptions,
        mutation: MutationOptions,
    ) !CreatedPathMutationResult {
        return self.impl().createScreen(create, mutation);
    }

    pub fn run(
        self: Self,
        options: RunOptions,
        mutation: MutationOptions,
    ) !CreatedTerminalPathMutationResult {
        return self.impl().run(options, mutation);
    }
};
pub const Screen = struct {
    const Self = @This();
    const Impl = HandleImpl(ScreenId, "screen", .{
        .get = .screen_get,
        .close = .screen_close,
        .rename = .screen_rename,
    });

    client: *Client,
    target: ScopedSelector(ScreenId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            ScreenId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            ScreenId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(ScreenId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?ScreenId {
        return self.impl().id();
    }

    pub fn pane(self: Self, child: anytype) Pane {
        return self.impl().pane(child);
    }

    pub fn refresh(self: Self) !OwnedScreenSnapshot {
        return self.impl().refresh();
    }

    pub fn listPanes(self: Self) !PaneList {
        return self.impl().listPanes();
    }

    pub fn listTerminals(self: Self) !TerminalList {
        return self.impl().listTerminals();
    }

    pub fn listBrowsers(self: Self) !BrowserList {
        return self.impl().listBrowsers();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn rename(
        self: Self,
        name: []const u8,
        mutation: MutationOptions,
    ) !ScreenMutationResult {
        return self.impl().rename(name, mutation);
    }

    pub fn clearName(
        self: Self,
        mutation: MutationOptions,
    ) !ScreenMutationResult {
        return self.impl().clearName(mutation);
    }

    pub fn focusScreen(
        self: Self,
        mutation: MutationOptions,
    ) !ScreenMutationResult {
        return self.impl().focusScreen(mutation);
    }

    pub fn exportLayout(self: Self) !OwnedLayoutDocument {
        return self.impl().exportLayout();
    }

    pub fn undoLayout(
        self: Self,
        options: UndoLayoutOptions,
        mutation: MutationOptions,
    ) !ScreenMutationResult {
        return self.impl().undoLayout(options, mutation);
    }

    pub fn createPane(
        self: Self,
        create: CreatePaneOptions,
        mutation: MutationOptions,
    ) !CreatedPathMutationResult {
        return self.impl().createPane(create, mutation);
    }
};

pub const Pane = struct {
    const Self = @This();
    const Impl = HandleImpl(PaneId, "pane", .{
        .get = .pane_get,
        .close = .pane_close,
        .rename = .pane_rename,
        .run = .pane_run,
    });

    client: *Client,
    target: ScopedSelector(PaneId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            PaneId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            PaneId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(PaneId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?PaneId {
        return self.impl().id();
    }

    pub fn tab(self: Self, child: anytype) Tab {
        return self.impl().tab(child);
    }

    pub fn refresh(self: Self) !OwnedPaneSnapshot {
        return self.impl().refresh();
    }

    pub fn listTabs(self: Self) !TabList {
        return self.impl().listTabs();
    }

    pub fn listTerminals(self: Self) !TerminalList {
        return self.impl().listTerminals();
    }

    pub fn listBrowsers(self: Self) !BrowserList {
        return self.impl().listBrowsers();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn rename(
        self: Self,
        name: []const u8,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().rename(name, mutation);
    }

    pub fn clearName(
        self: Self,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().clearName(mutation);
    }

    pub fn splitPane(
        self: Self,
        split: SplitOptions,
        mutation: MutationOptions,
    ) !CreatedPathMutationResult {
        return self.impl().splitPane(split, mutation);
    }

    pub fn focusPane(
        self: Self,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().focusPane(mutation);
    }

    pub fn focusDirection(
        self: Self,
        direction: Direction,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().focusDirection(direction, mutation);
    }

    pub fn neighbor(
        self: Self,
        direction: Direction,
    ) !OwnedPaneNeighborResult {
        return self.impl().neighbor(direction);
    }

    pub fn swapPane(
        self: Self,
        destination: MoveDestination,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().swapPane(destination, mutation);
    }

    pub fn zoomPane(
        self: Self,
        enabled: ?bool,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().zoomPane(enabled, mutation);
    }

    pub fn setSplitRatio(
        self: Self,
        split_id: SplitId,
        ratio: f64,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().setSplitRatio(
            split_id,
            ratio,
            mutation,
        );
    }

    pub fn setViewportWidth(
        self: Self,
        columns: u16,
        mutation: MutationOptions,
    ) !PaneMutationResult {
        return self.impl().setViewportWidth(columns, mutation);
    }

    pub fn run(
        self: Self,
        options: RunOptions,
        mutation: MutationOptions,
    ) !CreatedTerminalPathMutationResult {
        return self.impl().run(options, mutation);
    }

    pub fn createTerminalTab(
        self: Self,
        create: CreateTerminalTabOptions,
        mutation: MutationOptions,
    ) !CreatedTerminalPathMutationResult {
        return self.impl().createTerminalTab(create, mutation);
    }

    pub fn createBrowserTab(
        self: Self,
        create: CreateBrowserTabOptions,
        mutation: MutationOptions,
    ) !CreatedBrowserPathMutationResult {
        return self.impl().createBrowserTab(create, mutation);
    }
};

pub const Tab = struct {
    const Self = @This();
    const Impl = HandleImpl(TabId, "tab", .{
        .get = .tab_get,
        .close = .tab_close,
        .rename = .tab_rename,
    });

    client: *Client,
    target: ScopedSelector(TabId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            TabId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            TabId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(TabId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?TabId {
        return self.impl().id();
    }

    pub fn terminal(self: Self, child: anytype) Terminal {
        return self.impl().terminal(child);
    }

    pub fn browser(self: Self, child: anytype) Browser {
        return self.impl().browser(child);
    }

    pub fn refresh(self: Self) !OwnedTabSnapshot {
        return self.impl().refresh();
    }

    pub fn listTerminals(self: Self) !TerminalList {
        return self.impl().listTerminals();
    }

    pub fn listBrowsers(self: Self) !BrowserList {
        return self.impl().listBrowsers();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn rename(
        self: Self,
        name: []const u8,
        mutation: MutationOptions,
    ) !TabMutationResult {
        return self.impl().rename(name, mutation);
    }

    pub fn clearName(
        self: Self,
        mutation: MutationOptions,
    ) !TabMutationResult {
        return self.impl().clearName(mutation);
    }

    pub fn focusTab(
        self: Self,
        mutation: MutationOptions,
    ) !TabMutationResult {
        return self.impl().focusTab(mutation);
    }

    pub fn moveTab(
        self: Self,
        destination: MoveDestination,
        mutation: MutationOptions,
    ) !TabMutationResult {
        return self.impl().moveTab(destination, mutation);
    }
};
pub const Terminal = struct {
    const Self = @This();
    const Impl = HandleImpl(TerminalId, "terminal", .{
        .get = .terminal_get,
        .close = .terminal_close,
    });

    client: *Client,
    target: ScopedSelector(TerminalId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            TerminalId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            TerminalId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(TerminalId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?TerminalId {
        return self.impl().id();
    }

    pub fn refresh(self: Self) !OwnedTerminalSnapshot {
        return self.impl().refresh();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn readScreen(self: Self) !OwnedTerminalScreenResult {
        return self.impl().readScreen();
    }

    pub fn readState(self: Self) !OwnedTerminalStateResult {
        return self.impl().readState();
    }

    pub fn readHistory(
        self: Self,
        options: TerminalHistoryOptions,
    ) !OwnedTerminalHistoryResult {
        return self.impl().readHistory(options);
    }

    pub fn copy(
        self: Self,
        mode: ?TerminalCopyMode,
    ) !OwnedTerminalCopyResult {
        return self.impl().copy(mode);
    }

    pub fn processInfo(self: Self) !OwnedProcessInfoResult {
        return self.impl().processInfo();
    }

    pub fn waitFor(
        self: Self,
        pattern: []const u8,
        timeout_ms: ?u64,
    ) !OwnedTerminalWaitResult {
        return self.impl().waitFor(pattern, timeout_ms);
    }

    pub fn waitForExit(
        self: Self,
        timeout_ms: ?u64,
    ) !OwnedTerminalWaitExitResult {
        return self.impl().waitForExit(timeout_ms);
    }

    pub fn clearHistory(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().clearHistory(mutation);
    }

    pub fn writeText(
        self: Self,
        text: []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().writeText(text, mutation);
    }

    pub fn writeBytes(
        self: Self,
        bytes: []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().writeBytes(bytes, mutation);
    }

    pub fn sendKeys(
        self: Self,
        keys: []const []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendKeys(keys, mutation);
    }

    pub fn sendMouse(
        self: Self,
        mouse: TerminalMouseOptions,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendMouse(mouse, mutation);
    }

    pub fn setInputFocus(
        self: Self,
        focused: bool,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().setInputFocus(focused, mutation);
    }

    pub fn moveTerminal(
        self: Self,
        destination: MoveDestination,
        mutation: MutationOptions,
    ) !TerminalMutationResult {
        return self.impl().moveTerminal(destination, mutation);
    }

    pub fn projectTerminal(
        self: Self,
        options: TerminalProjectOptions,
        mutation: MutationOptions,
    ) !TabMutationResult {
        return self.impl().projectTerminal(options, mutation);
    }

    pub fn scroll(
        self: Self,
        delta_rows: i32,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().scroll(delta_rows, mutation);
    }

    pub fn attachTerminal(self: Self) !TerminalAttachmentStream {
        return self.impl().attachTerminal();
    }

    pub fn attachTerminalWith(
        self: Self,
        options: TerminalAttachOptions,
    ) !TerminalAttachmentStream {
        return self.impl().attachTerminalWith(options);
    }

    pub fn rendererGrant(self: Self) !*RendererGrant {
        return self.impl().rendererGrant();
    }

    pub fn rendererGrantWith(
        self: Self,
        request: RendererGrantRequest,
    ) !*RendererGrant {
        return self.impl().rendererGrantWith(request);
    }
};

pub const Browser = struct {
    const Self = @This();
    const Impl = HandleImpl(BrowserId, "browser", .{
        .get = .browser_get,
        .close = .browser_close,
    });

    client: *Client,
    target: ScopedSelector(BrowserId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            BrowserId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            BrowserId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(BrowserId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?BrowserId {
        return self.impl().id();
    }

    pub fn refresh(self: Self) !OwnedBrowserSnapshot {
        return self.impl().refresh();
    }

    pub fn close(
        self: Self,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().close(mutation);
    }

    pub fn navigate(
        self: Self,
        url: []const u8,
        mutation: MutationOptions,
    ) !BrowserMutationResult {
        return self.impl().navigate(url, mutation);
    }

    pub fn browserBack(
        self: Self,
        mutation: MutationOptions,
    ) !BrowserMutationResult {
        return self.impl().browserBack(mutation);
    }

    pub fn browserForward(
        self: Self,
        mutation: MutationOptions,
    ) !BrowserMutationResult {
        return self.impl().browserForward(mutation);
    }

    pub fn reloadBrowser(
        self: Self,
        mutation: MutationOptions,
    ) !BrowserMutationResult {
        return self.impl().reloadBrowser(mutation);
    }

    pub fn activateBrowser(
        self: Self,
        mutation: MutationOptions,
    ) !BrowserMutationResult {
        return self.impl().activateBrowser(mutation);
    }

    pub fn sendBrowserKey(
        self: Self,
        key: BrowserKeyOptions,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendBrowserKey(key, mutation);
    }

    pub fn sendBrowserText(
        self: Self,
        text: []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendBrowserText(text, mutation);
    }

    pub fn sendBrowserMouse(
        self: Self,
        mouse: BrowserMouseOptions,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendBrowserMouse(mouse, mutation);
    }

    pub fn sendBrowserWheel(
        self: Self,
        wheel: BrowserWheelOptions,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendBrowserWheel(wheel, mutation);
    }

    pub fn attachBrowser(self: Self) !BrowserAttachmentStream {
        return self.impl().attachBrowser();
    }

    pub fn attachBrowserWith(
        self: Self,
        options: BrowserAttachOptions,
    ) !BrowserAttachmentStream {
        return self.impl().attachBrowserWith(options);
    }
};
pub const ConnectedClient = struct {
    const Self = @This();
    const Impl = HandleImpl(ConnectedClientId, "client", .{
        .get = .client_get,
    });

    client: *Client,
    target: ScopedSelector(ConnectedClientId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            ConnectedClientId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            ConnectedClientId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(ConnectedClientId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?ConnectedClientId {
        return self.impl().id();
    }

    pub fn refresh(self: Self) !OwnedClientSnapshot {
        return self.impl().refresh();
    }

    pub fn updateMetadata(
        self: Self,
        update: ClientMetadataUpdate,
    ) !OwnedClientSnapshot {
        return self.impl().updateMetadata(update);
    }

    pub fn setCellPixels(
        self: Self,
        width_px: u32,
        height_px: u32,
    ) !OwnedCellPixelsResult {
        return self.impl().setCellPixels(width_px, height_px);
    }

    pub fn setSizing(
        self: Self,
        terminal_id: TerminalId,
        enabled: bool,
        exclusive: ?bool,
    ) !OwnedClientSnapshot {
        return self.impl().setSizing(
            terminal_id,
            enabled,
            exclusive,
        );
    }

    pub fn releaseSizing(
        self: Self,
        terminal_id: TerminalId,
    ) !OwnedClientSnapshot {
        return self.impl().releaseSizing(terminal_id);
    }

    pub fn detachClient(self: Self) !OwnedEmptyResult {
        return self.impl().detachClient();
    }
};

pub const PairingRequest = struct {
    const Self = @This();
    const Impl = HandleImpl(PairingRequestId, "pairing_request", .{
        .get = .pairing_request_list,
    });

    client: *Client,
    target: ScopedSelector(PairingRequestId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            PairingRequestId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            PairingRequestId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(PairingRequestId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?PairingRequestId {
        return self.impl().id();
    }

    pub fn resolvePairing(
        self: Self,
        decision: PairingDecision,
        mutation: MutationOptions,
    ) !PairingResolutionMutationResult {
        return self.impl().resolvePairing(decision, mutation);
    }
};

pub const FrontendProjection = struct {
    const Self = @This();
    const Impl = HandleImpl(
        FrontendProjectionId,
        "frontend_projection",
        .{ .get = .frontend_projection_get },
    );

    client: *Client,
    target: ScopedSelector(FrontendProjectionId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            FrontendProjectionId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            FrontendProjectionId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(FrontendProjectionId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?FrontendProjectionId {
        return self.impl().id();
    }

    pub fn refresh(self: Self) !OwnedFrontendProjectionSnapshot {
        return self.impl().refresh();
    }

    pub fn putProjection(
        self: Self,
        projection: ProjectionPutOptions,
        mutation: MutationOptions,
    ) !FrontendProjectionMutationResult {
        return self.impl().putProjection(projection, mutation);
    }
};

pub const OwnedSidebarViewSnapshot = OwnedValue(
    SidebarViewSnapshot,
);

pub const SidebarView = struct {
    const Self = @This();
    const Impl = HandleImpl(SidebarViewId, "sidebar_view", .{
        .get = .sidebar_view_get,
    });

    client: *Client,
    target: ScopedSelector(SidebarViewId),

    pub fn init(client: *Client, selection: anytype) Self {
        return initHandleFacade(
            Self,
            SidebarViewId,
            client,
            selection,
            .{},
        );
    }

    fn initScoped(
        client: *Client,
        selection: anytype,
        ancestors: HandleRoute,
    ) Self {
        return initHandleFacade(
            Self,
            SidebarViewId,
            client,
            selection,
            ancestors,
        );
    }

    fn impl(self: Self) Impl {
        return handleFacadeImpl(Impl, self);
    }

    pub fn selector(self: Self) Selector(SidebarViewId) {
        return self.target.selector;
    }

    pub fn id(self: Self) ?SidebarViewId {
        return self.impl().id();
    }

    pub fn refresh(self: Self) !OwnedSidebarViewSnapshot {
        return self.impl().refresh();
    }

    pub fn attachSidebar(self: Self) !SidebarViewStream {
        return self.impl().attachSidebar();
    }

    pub fn sendSidebarInput(
        self: Self,
        bytes: []const u8,
        mutation: MutationOptions,
    ) !EmptyMutationResult {
        return self.impl().sendSidebarInput(bytes, mutation);
    }

    pub fn resizeSidebar(
        self: Self,
        cols: u16,
        rows: u16,
        mutation: MutationOptions,
    ) !SidebarViewMutationResult {
        return self.impl().resizeSidebar(cols, rows, mutation);
    }

    pub fn reloadSidebar(
        self: Self,
        mutation: MutationOptions,
    ) !SidebarViewMutationResult {
        return self.impl().reloadSidebar(mutation);
    }
};
const FakeMode = enum {
    success,
    remote_error,
    typed_catalog,
    delayed_stream_item,
    dropped_mutation_timeout,
    dropped_mutation_disconnect,
    abandoned_wait_cancel_true,
    abandoned_wait_cancel_false,
    abandoned_wait_malformed_target,
    abandoned_wait_malformed_cancel,
};

const FakeStreamOpenAck = enum {
    matching,
    matching_with_cursor,
    missing_result,
    missing_stream_id,
    mismatched_stream_id,
    non_object,
    unknown_field,
    null_cursor,
    malformed_cursor,
    cursor_unknown_field,
    empty_cursor_generation,
    oversized_cursor_generation,
};

const FakeStreamOpenPreamble = enum {
    none,
    item_before_ack,
    item_then_end_before_ack,
    count_overflow,
    malformed_item,
    wrong_item,
    wrong_end,
    item_after_end,
};

const FakeCancelResponse = enum {
    empty,
    non_empty,
    invalid_protocol,
    rejected,
    extra_field,
    success_with_error,
    failure_with_result,
    malformed_error,
};

const FakeCancelEnd = enum {
    matching,
    missing,
    invalid_protocol,
    missing_reason,
    wrong_stream_id,
    wrong_reason,
    unknown_field,
    null_cursor,
    malformed_cursor,
    null_recovery,
    unexpected_error,
};

const FakeCancelDelivery = enum {
    immediate,
    stale_items,
    fragmented,
    valid_known_item_after_end,
    malformed_known_item,
};

const fake_delayed_stream_wait_ms: u64 = 15;

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

const fake_notification_snapshot_json =
    "{\"id\":\"notification_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"title\":\"Build complete\",\"body\":\"All tests passed\"," ++
    "\"level\":\"info\",\"terminal_id\":" ++
    "\"term_0123456789abcdef0123456789abcdef\"," ++
    "\"created_at_ms\":\"18446744073709551615\",\"unread\":true," ++
    "\"extra\":{\"notification_future\":true}}";

const fake_agent_snapshot_json =
    "{\"id\":\"agent_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"terminal_id\":\"term_0123456789abcdef0123456789abcdef\"," ++
    "\"state\":\"working\",\"source\":\"hook\"," ++
    "\"updated_at_ms\":\"18446744073709551614\"," ++
    "\"source_session\":null,\"extra\":{\"agent_future\":true}}";

const fake_pairing_snapshot_json =
    "{\"id\":\"pairing_cccccccccccccccccccccccccccccccc\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"peer\":\"tablet\",\"code\":\"123456\"," ++
    "\"expires_in_seconds\":\"90\",\"status\":\"accepted\"," ++
    "\"extra\":{\"pairing_future\":true}}";

const fake_projection_snapshot_json =
    "{\"id\":\"projection_dddddddddddddddddddddddddddddddd\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"frontend_id\":\"swift-frontend\",\"window_id\":\"window-1\"," ++
    "\"generation\":\"window-generation-1\"," ++
    "\"projection\":{\"sidebar\":\"compact\"}," ++
    "\"projection_revision\":\"3\"," ++
    "\"extra\":{\"projection_future\":true}}";

const fake_sidebar_snapshot_json =
    "{\"id\":\"sidebar_view_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"," ++
    "\"session_id\":\"session_22222222222222222222222222222222\"," ++
    "\"cols\":40,\"rows\":30,\"running\":true," ++
    "\"extra\":{\"sidebar_future\":true}}";

const FakeShared = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    read_cursor: usize = 0,
    processed: usize = 0,
    mode: FakeMode,
    closed: bool = false,
    stream_open_ack: FakeStreamOpenAck = .matching,
    stream_open_preamble: FakeStreamOpenPreamble = .none,
    cancel_response: FakeCancelResponse = .empty,
    cancel_end: FakeCancelEnd = .matching,
    cancel_delivery: FakeCancelDelivery = .immediate,
    cancel_delivery_active: bool = false,
    cancel_read_delay_ms: u32 = 0,
    cancel_read_calls: usize = 0,
    cancel_first_read_timeout_ms: ?u32 = null,
    cancel_last_read_timeout_ms: ?u32 = null,
    write_calls: usize = 0,
    fail_write_call: ?usize = null,
    delayed_stream_id: ?[]u8 = null,
    delayed_stream_item_emitted: bool = false,
    delayed_stream_open_read_observed: bool = false,
    delayed_stream_open_timeout_ms: ?u32 = null,
    delayed_stream_read_started: bool = false,
    delayed_stream_read_had_deadline: bool = false,
    read_failure: ?anyerror = null,
    abandoned_request_id: ?[]u8 = null,
    request_cancel_count: usize = 0,
    request_cancel_route_ok: bool = false,

    fn deinit(self: *FakeShared) void {
        if (self.delayed_stream_id) |stream_id| {
            self.allocator.free(stream_id);
        }
        if (self.abandoned_request_id) |request_id| {
            self.allocator.free(request_id);
        }
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    fn abandonedWaitMode(self: *const FakeShared) bool {
        return switch (self.mode) {
            .abandoned_wait_cancel_true,
            .abandoned_wait_cancel_false,
            .abandoned_wait_malformed_target,
            .abandoned_wait_malformed_cancel,
            => true,
            else => false,
        };
    }

    fn appendInput(self: *FakeShared, value: []const u8) !void {
        try self.input.appendSlice(self.allocator, value);
        try self.input.append(self.allocator, '\n');
    }

    fn appendSessionStreamItem(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        return self.appendSessionStreamItemAt(stream_id, 1);
    }

    fn appendSessionStreamItemAt(
        self: *FakeShared,
        stream_id: []const u8,
        sequence: usize,
    ) !void {
        const item = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"stream_item\",\"stream_id\":\"{s}\"," ++
                "\"sequence\":\"{d}\",\"cursor\":{{\"generation\":" ++
                "\"g\",\"revision\":\"{d}\"}},\"item\":{{\"kind\":" ++
                "\"future.event\",\"data\":{{\"x\":1}}," ++
                "\"future\":true}}}}",
            .{ stream_id, sequence, sequence },
        );
        defer self.allocator.free(item);
        try self.appendInput(item);
    }

    fn appendJournalStreamItem(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        const item = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"stream_item\",\"stream_id\":\"{s}\"," ++
                "\"sequence\":\"1\",\"cursor\":{{\"generation\":" ++
                "\"session_11111111111111111111111111111111\"," ++
                "\"revision\":\"1\"}},\"item\":{{" ++
                "\"sequence\":\"1\",\"event_id\":\"evt_1\"," ++
                "\"schema_version\":1,\"kind\":\"workspace.focus\"," ++
                "\"class\":\"state\",\"replay\":\"required\"," ++
                "\"occurred_at_ms\":\"10\",\"committed_at_ms\":\"11\"," ++
                "\"producer\":{{\"kind\":\"resource_api\",\"id\":\"client_1\"}}," ++
                "\"authority\":null,\"causation_id\":null," ++
                "\"correlation_id\":null,\"causation_depth\":0," ++
                "\"subjects\":[{{\"kind\":\"workspace\",\"id\":\"ws_1\"}}]," ++
                "\"sensitivity\":\"public\",\"payload\":{{\"focused\":true}}," ++
                "\"resource_revision\":\"4\"," ++
                "\"previous_resource_revision\":\"3\"}}}}",
            .{stream_id},
        );
        defer self.allocator.free(item);
        try self.appendInput(item);
    }

    fn appendCompletedStreamEnd(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        const end = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"stream_end\",\"stream_id\":\"{s}\"," ++
                "\"reason\":\"completed\",\"cursor\":{{" ++
                "\"generation\":\"g\",\"revision\":\"1\"}}}}",
            .{stream_id},
        );
        defer self.allocator.free(end);
        try self.appendInput(end);
    }

    fn appendStreamOpenPreamble(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        switch (self.stream_open_preamble) {
            .none => {},
            .item_before_ack => try self.appendSessionStreamItemAt(
                stream_id,
                1,
            ),
            .item_then_end_before_ack => {
                try self.appendSessionStreamItemAt(stream_id, 1);
                try self.appendCompletedStreamEnd(stream_id);
            },
            .count_overflow => {
                for (0..RawStream.max_buffered_items + 1) |index| {
                    try self.appendSessionStreamItemAt(
                        stream_id,
                        index + 1,
                    );
                }
            },
            .malformed_item => {
                const item = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                        "\"stream_item\",\"stream_id\":\"{s}\"," ++
                        "\"sequence\":1,\"item\":{{\"kind\":" ++
                        "\"future.event\"}}}}",
                    .{stream_id},
                );
                defer self.allocator.free(item);
                try self.appendInput(item);
            },
            .wrong_item => try self.appendSessionStreamItemAt(
                "stream_ffffffffffffffffffffffffffffffff",
                1,
            ),
            .wrong_end => try self.appendCompletedStreamEnd(
                "stream_ffffffffffffffffffffffffffffffff",
            ),
            .item_after_end => {
                try self.appendCompletedStreamEnd(stream_id);
                try self.appendSessionStreamItemAt(stream_id, 2);
            },
        }
    }

    fn appendValidSessionDeltaItem(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        const item = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"stream_item\",\"stream_id\":\"{s}\"," ++
                "\"sequence\":\"2\",\"cursor\":{{\"generation\":" ++
                "\"g\",\"revision\":\"2\"}},\"item\":{{\"kind\":" ++
                "\"delta\",\"cursor\":{{\"generation\":\"g\"," ++
                "\"revision\":\"2\"}},\"previous_revision\":\"1\"," ++
                "\"revision\":\"2\",\"changes\":[]}}}}",
            .{stream_id},
        );
        defer self.allocator.free(item);
        try self.appendInput(item);
    }

    fn appendStreamOpenResponse(
        self: *FakeShared,
        request_id: []const u8,
        stream_id: []const u8,
        is_attachment: bool,
    ) !void {
        if (self.stream_open_ack == .missing_result) {
            const response = try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true}}",
                .{request_id},
            );
            defer self.allocator.free(response);
            try self.appendInput(response);
            return;
        }
        const oversized_generation = "g" ** 129;
        const result = switch (self.stream_open_ack) {
            .matching => if (is_attachment)
                try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"stream_id\":\"{s}\"," ++
                        "\"attachment_lease\":\"attachment-lease\"}}",
                    .{stream_id},
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"stream_id\":\"{s}\"}}",
                    .{stream_id},
                ),
            .matching_with_cursor => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":\"2\"}}}}",
                .{stream_id},
            ),
            .missing_stream_id => try self.allocator.dupe(u8, "{}"),
            .mismatched_stream_id => try self.allocator.dupe(
                u8,
                "{\"stream_id\":" ++
                    "\"stream_ffffffffffffffffffffffffffffffff\"}",
            ),
            .non_object => try self.allocator.dupe(u8, "[]"),
            .unknown_field => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"future\":true}}",
                .{stream_id},
            ),
            .null_cursor => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":null}}",
                .{stream_id},
            ),
            .malformed_cursor => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":2}}}}",
                .{stream_id},
            ),
            .cursor_unknown_field => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":\"2\"," ++
                    "\"future\":true}}}}",
                .{stream_id},
            ),
            .empty_cursor_generation => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":{{" ++
                    "\"generation\":\"\",\"revision\":\"2\"}}}}",
                .{stream_id},
            ),
            .oversized_cursor_generation => try std.fmt.allocPrint(
                self.allocator,
                "{{\"stream_id\":\"{s}\",\"cursor\":{{" ++
                    "\"generation\":\"{s}\",\"revision\":\"2\"}}}}",
                .{ stream_id, oversized_generation },
            ),
            .missing_result => unreachable,
        };
        defer self.allocator.free(result);
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                "\"result\":{s}}}",
            .{ request_id, result },
        );
        defer self.allocator.free(response);
        try self.appendInput(response);
    }

    fn appendCancelResponse(
        self: *FakeShared,
        request_id: []const u8,
    ) !void {
        const response = switch (self.cancel_response) {
            .empty => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                    "\"result\":{{}}}}",
                .{request_id},
            ),
            .non_empty => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                    "\"result\":{{\"unexpected\":true}}}}",
                .{request_id},
            ),
            .invalid_protocol => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/999\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                    "\"result\":{{}}}}",
                .{request_id},
            ),
            .rejected => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":false," ++
                    "\"error\":{{\"code\":\"stream.cancel_rejected\"," ++
                    "\"message\":\"cancel rejected\",\"details\":{{}}," ++
                    "\"retryable\":false}}}}",
                .{request_id},
            ),
            .extra_field => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                    "\"result\":{{}},\"future\":true}}",
                .{request_id},
            ),
            .success_with_error => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                    "\"result\":{{}},\"error\":{{\"code\":\"failed\"," ++
                    "\"message\":\"bad\",\"details\":{{}}," ++
                    "\"retryable\":false}}}}",
                .{request_id},
            ),
            .failure_with_result => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":false," ++
                    "\"result\":{{}},\"error\":{{\"code\":\"failed\"," ++
                    "\"message\":\"bad\",\"details\":{{}}," ++
                    "\"retryable\":false}}}}",
                .{request_id},
            ),
            .malformed_error => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"response\",\"id\":\"{s}\",\"ok\":false," ++
                    "\"error\":{{\"code\":\"failed\"," ++
                    "\"message\":\"bad\",\"details\":{{}}," ++
                    "\"retryable\":false,\"future\":true}}}}",
                .{request_id},
            ),
        };
        defer self.allocator.free(response);
        try self.appendInput(response);
    }

    fn appendCancelEnd(
        self: *FakeShared,
        stream_id: []const u8,
    ) !void {
        if (self.cancel_end == .missing) return;
        const end = switch (self.cancel_end) {
            .matching => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":\"3\"}}}}",
                .{stream_id},
            ),
            .invalid_protocol => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/999\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\"}}",
                .{stream_id},
            ),
            .missing_reason => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"}}",
                .{stream_id},
            ),
            .wrong_stream_id => try self.allocator.dupe(
                u8,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":" ++
                    "\"stream_ffffffffffffffffffffffffffffffff\"," ++
                    "\"reason\":\"canceled\"}",
            ),
            .wrong_reason => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"completed\"}}",
                .{stream_id},
            ),
            .unknown_field => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"future\":true}}",
                .{stream_id},
            ),
            .null_cursor => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"cursor\":null}}",
                .{stream_id},
            ),
            .malformed_cursor => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":3}}}}",
                .{stream_id},
            ),
            .null_recovery => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"recovery\":null}}",
                .{stream_id},
            ),
            .unexpected_error => try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_end\",\"stream_id\":\"{s}\"," ++
                    "\"reason\":\"canceled\",\"error\":{{" ++
                    "\"code\":\"failed\",\"message\":\"bad\"," ++
                    "\"details\":{{}},\"retryable\":false}}}}",
                .{stream_id},
            ),
            .missing => unreachable,
        };
        defer self.allocator.free(end);
        try self.appendInput(end);
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
            if (self.abandonedWaitMode()) {
                if (std.mem.eql(u8, operation, "terminal.wait") or
                    std.mem.eql(u8, operation, "terminal.wait_exit"))
                {
                    if (self.abandoned_request_id != null) {
                        return error.DuplicateAbandonedRequest;
                    }
                    self.abandoned_request_id = try self.allocator.dupe(
                        u8,
                        id,
                    );
                    continue;
                }
                if (std.mem.eql(u8, operation, "request.cancel")) {
                    self.request_cancel_count += 1;
                    const params = switch (object.get("params") orelse
                        return error.MissingField) {
                        .object => |item| item,
                        else => return error.ExpectedObject,
                    };
                    const target_id = try objectString(
                        params,
                        "request_id",
                    );
                    self.request_cancel_route_ok =
                        self.request_cancel_count == 1 and
                        params.count() == 1 and
                        self.abandoned_request_id != null and
                        std.mem.eql(
                            u8,
                            target_id,
                            self.abandoned_request_id.?,
                        ) and
                        object.get("idempotency_key") == null;
                    const result = switch (self.mode) {
                        .abandoned_wait_cancel_true => "{\"canceled\":true}",
                        .abandoned_wait_cancel_false,
                        .abandoned_wait_malformed_target,
                        => "{\"canceled\":false}",
                        .abandoned_wait_malformed_cancel => "{\"canceled\":true,\"future\":true}",
                        else => unreachable,
                    };
                    const response = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                            "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                            "\"result\":{s}}}",
                        .{ id, result },
                    );
                    defer self.allocator.free(response);
                    try self.appendInput(response);
                    if (self.mode == .abandoned_wait_cancel_false or
                        self.mode == .abandoned_wait_malformed_target)
                    {
                        const target_result = if (self.mode ==
                            .abandoned_wait_malformed_target)
                            "{\"matched\":true}"
                        else
                            "{\"matched\":true,\"text\":\"raced\"}";
                        const target_response = try std.fmt.allocPrint(
                            self.allocator,
                            "{{\"protocol\":\"cmux.protocol/2\"," ++
                                "\"type\":\"response\",\"id\":\"{s}\"," ++
                                "\"ok\":true,\"result\":{s}}}",
                            .{ self.abandoned_request_id.?, target_result },
                        );
                        defer self.allocator.free(target_response);
                        try self.appendInput(target_response);
                    }
                    continue;
                }
                if (std.mem.eql(u8, operation, "session.ping")) {
                    const response = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                            "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                            "\"result\":{{\"alive\":true,\"cursor\":{{" ++
                            "\"generation\":\"g\",\"revision\":\"1\"}}}}}}",
                        .{id},
                    );
                    defer self.allocator.free(response);
                    try self.appendInput(response);
                    continue;
                }
            }
            if (self.mode == .remote_error) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":false," ++ "\"error\":{{\"code\":\"mutation.indeterminate\"," ++ "\"message\":\"external effect may have committed\"," ++ "\"details\":{{\"idempotency_key\":" ++ "\"indeterminate-test-key\",\"operation\":" ++ "\"workspace.rename\",\"recovery\":" ++ "\"inspect_state_then_retry_with_new_key\"}}," ++ "\"retryable\":false}}}}",
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
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.wait_exit",
                    ))
                        "{\"state\":\"pending\",\"terminal_id\":" ++
                            "\"term_0123456789abcdef0123456789abcdef\"," ++
                            "\"lifecycle\":\"running\",\"revision\":\"11\"}"
                    else if (std.mem.eql(u8, operation, "terminal.copy"))
                        "{\"mode\":\"selection\",\"text\":\"copied\"}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.process.get",
                    ))
                        "{\"pid\":123,\"executable\":\"/bin/zsh\"," ++
                            "\"argv\":[\"zsh\",\"-l\"],\"cwd\":\"/tmp\"," ++
                            "\"foreground_cwd\":\"/tmp/subshell\"," ++
                            "\"children\":[124,125]}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.viewer.resize",
                    ))
                        "{\"accepted\":true,\"size\":{" ++
                            "\"cols\":100,\"rows\":30}," ++
                            "\"outcome\":\"applied\"}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "terminal.viewer.release",
                    ))
                        "{\"outcome\":\"applied\"}"
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
                            "\"width_px\":1440,\"height_px\":900}," ++
                            "\"outcome\":\"applied\"}"
                    else if (std.mem.eql(
                        u8,
                        operation,
                        "browser.viewer.release",
                    ))
                        "{\"outcome\":\"applied\"}"
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
                        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
                        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
            const facade_mutation_value: ?[]const u8 =
                if (std.mem.eql(u8, operation, "screen.layout.undo"))
                    fake_screen_snapshot_json
                else if (std.mem.eql(u8, operation, "notification.create"))
                    fake_notification_snapshot_json
                else if (std.mem.eql(u8, operation, "agent.report"))
                    fake_agent_snapshot_json
                else if (std.mem.eql(
                    u8,
                    operation,
                    "pairing_request.resolve",
                ))
                    "{\"pairing_request\":" ++
                        fake_pairing_snapshot_json ++ "}"
                else if (std.mem.eql(
                    u8,
                    operation,
                    "frontend_projection.put",
                ))
                    fake_projection_snapshot_json
                else if (std.mem.eql(
                    u8,
                    operation,
                    "sidebar_view.ensure",
                ) or std.mem.eql(
                    u8,
                    operation,
                    "sidebar_view.resize",
                ) or std.mem.eql(
                    u8,
                    operation,
                    "sidebar_view.reload",
                ))
                    fake_sidebar_snapshot_json
                else if (std.mem.eql(
                    u8,
                    operation,
                    "sidebar_view.input",
                ))
                    "{}"
                else
                    null;
            if (facade_mutation_value) |value| {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                        "\"response\",\"id\":\"{s}\",\"ok\":true," ++
                        "\"result\":{{\"value\":{s}," ++
                        "\"generation\":\"g\",\"revision\":\"7\"," ++
                        "\"replayed\":false}}}}",
                    .{ id, value },
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
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{\"endpoint\":\"/tmp/renderer.sock\"," ++ "\"terminal_id\":" ++ "\"term_0123456789abcdef0123456789abcdef\"," ++ "\"token\":\"renderer-secret\"," ++ "\"rights\":[\"read\",\"input\"]," ++ "\"ttl_ms\":5000}}}}",
                    .{id},
                );
                defer self.allocator.free(response);
                try self.appendInput(response);
                continue;
            }
            if (std.mem.eql(u8, operation, "client.detach")) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
            ) or std.mem.eql(
                u8,
                operation,
                "browser.input.mouse",
            ) or std.mem.eql(
                u8,
                operation,
                "browser.input.wheel",
            )) {
                const response = try std.fmt.allocPrint(
                    self.allocator,
                    "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
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
            if (std.mem.eql(u8, operation, "terminal.attach") or
                std.mem.eql(u8, operation, "browser.attach") or
                std.mem.eql(u8, operation, "sidebar_view.attach"))
            {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                try self.appendStreamOpenResponse(
                    id,
                    try objectString(params, "stream_id"),
                    !std.mem.eql(u8, operation, "sidebar_view.attach"),
                );
                continue;
            }
            if (std.mem.eql(u8, operation, "session.events")) {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                const stream_id = try objectString(params, "stream_id");
                try self.appendStreamOpenPreamble(stream_id);
                try self.appendStreamOpenResponse(id, stream_id, false);
                if (self.mode == .delayed_stream_item) {
                    self.delayed_stream_id = try self.allocator.dupe(
                        u8,
                        stream_id,
                    );
                } else if (self.stream_open_preamble == .none) {
                    try self.appendSessionStreamItem(stream_id);
                } else if (self.stream_open_preamble == .item_before_ack) {
                    try self.appendSessionStreamItemAt(stream_id, 2);
                }
                continue;
            }
            if (std.mem.eql(
                u8,
                operation,
                "session.journal.subscribe",
            )) {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                const stream_id = try objectString(params, "stream_id");
                try self.appendStreamOpenResponse(id, stream_id, false);
                try self.appendJournalStreamItem(stream_id);
                continue;
            }
            if (std.mem.eql(u8, operation, "stream.cancel")) {
                const params = switch (object.get("params").?) {
                    .object => |item| item,
                    else => return error.ExpectedObject,
                };
                const stream_id = try objectString(params, "stream");
                self.cancel_delivery_active = true;
                if (self.cancel_delivery == .stale_items) {
                    for (0..8) |_| {
                        try self.appendSessionStreamItem(stream_id);
                    }
                }
                switch (self.cancel_delivery) {
                    .valid_known_item_after_end => {
                        try self.appendCancelEnd(stream_id);
                        try self.appendValidSessionDeltaItem(stream_id);
                    },
                    .malformed_known_item => {
                        try self.appendCancelEnd(stream_id);
                        const malformed = try std.fmt.allocPrint(
                            self.allocator,
                            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                                "\"stream_item\",\"stream_id\":\"{s}\"," ++
                                "\"sequence\":\"2\",\"cursor\":{{" ++
                                "\"generation\":\"g\",\"revision\":\"2\"}}," ++
                                "\"item\":{{\"kind\":\"snapshot\"," ++
                                "\"future\":true}}}}",
                            .{stream_id},
                        );
                        defer self.allocator.free(malformed);
                        try self.appendInput(malformed);
                    },
                    else => try self.appendCancelEnd(stream_id),
                }
                try self.appendCancelResponse(id);
                continue;
            }
            const response = try std.fmt.allocPrint(
                self.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++ "\"response\",\"id\":\"{s}\",\"ok\":true," ++ "\"result\":{{\"value\":{{\"kind\":\"terminal\"," ++ "\"workspace_id\":\"ws_0123456789abcdef0123456789abcdef\"," ++ "\"screen_id\":\"screen_0123456789abcdef0123456789abcdef\"," ++ "\"pane_id\":\"pane_0123456789abcdef0123456789abcdef\"," ++ "\"tab_id\":\"tab_0123456789abcdef0123456789abcdef\"," ++ "\"terminal_id\":\"term_0123456789abcdef0123456789abcdef\"}}," ++ "\"generation\":\"g\",\"revision\":\"7\"," ++ "\"replayed\":false}}}}",
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

    fn noteCancelRead(
        self: *FakeConnection,
        timeout_ms: ?u32,
    ) void {
        if (!self.shared.cancel_delivery_active) return;
        self.shared.cancel_read_calls += 1;
        if (self.shared.cancel_first_read_timeout_ms == null) {
            self.shared.cancel_first_read_timeout_ms = timeout_ms;
        }
        self.shared.cancel_last_read_timeout_ms = timeout_ms;
    }

    pub fn read(
        self: *FakeConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        if (self.shared.read_failure) |failure| return failure;
        if (self.shared.mode == .delayed_stream_item and
            self.shared.delayed_stream_id != null and
            !self.shared.delayed_stream_open_read_observed and
            self.shared.read_cursor < self.shared.input.items.len)
        {
            self.shared.delayed_stream_open_read_observed = true;
            self.shared.delayed_stream_open_timeout_ms = timeout_ms;
        }
        if (self.shared.read_cursor == self.shared.input.items.len) {
            if (self.shared.mode == .delayed_stream_item and
                !self.shared.delayed_stream_item_emitted)
            {
                self.shared.delayed_stream_read_started = true;
                self.shared.delayed_stream_read_had_deadline =
                    timeout_ms != null;
                if (timeout_ms) |deadline_ms| {
                    std.Thread.sleep(
                        (@as(u64, deadline_ms) + 1) *
                            std.time.ns_per_ms,
                    );
                    return error.Timeout;
                }
                std.Thread.sleep(
                    fake_delayed_stream_wait_ms * std.time.ns_per_ms,
                );
                try self.shared.appendSessionStreamItem(
                    self.shared.delayed_stream_id orelse
                        return error.MissingDelayedStreamId,
                );
                self.shared.delayed_stream_item_emitted = true;
            }
            if (self.shared.read_cursor == self.shared.input.items.len) {
                if (self.shared.abandonedWaitMode() and
                    self.shared.abandoned_request_id != null and
                    self.shared.request_cancel_count == 0)
                {
                    if (timeout_ms) |milliseconds| {
                        std.Thread.sleep(
                            @as(u64, milliseconds) *
                                std.time.ns_per_ms,
                        );
                    }
                    return error.Timeout;
                }
                if (self.shared.cancel_delivery_active and
                    self.shared.cancel_end == .missing)
                {
                    self.noteCancelRead(timeout_ms);
                    if (timeout_ms) |milliseconds| {
                        std.Thread.sleep(
                            @as(u64, milliseconds) * std.time.ns_per_ms,
                        );
                        return error.Timeout;
                    }
                }
                if (self.shared.mode == .dropped_mutation_timeout) {
                    return error.Timeout;
                }
                return error.ConnectionClosed;
            }
        }
        if (self.shared.cancel_delivery_active) {
            self.noteCancelRead(timeout_ms);
            const delay_ms = self.shared.cancel_read_delay_ms;
            if (delay_ms > 0) {
                if (timeout_ms) |remaining_ms| {
                    if (remaining_ms <= delay_ms) {
                        std.Thread.sleep(
                            @as(u64, remaining_ms) * std.time.ns_per_ms,
                        );
                        return error.Timeout;
                    }
                }
                std.Thread.sleep(
                    @as(u64, delay_ms) * std.time.ns_per_ms,
                );
            }
        }
        var count = @min(
            buffer.len,
            self.shared.input.items.len - self.shared.read_cursor,
        );
        if (self.shared.cancel_delivery_active) {
            switch (self.shared.cancel_delivery) {
                .immediate,
                .valid_known_item_after_end,
                .malformed_known_item,
                => {},
                .stale_items => {
                    const remaining = self.shared.input.items[self.shared.read_cursor..];
                    if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline| {
                        count = @min(count, newline + 1);
                    }
                },
                .fragmented => count = @min(count, 16),
            }
        }
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
        if (self.shared.closed) return error.ConnectionClosed;
        self.shared.write_calls += 1;
        if (self.shared.fail_write_call == self.shared.write_calls) {
            return error.InjectedWriteFailure;
        }
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

const BlockingResourceConnection = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    reading: bool = false,
    closed: bool = false,
    writes: usize = 0,

    fn create() !*BlockingResourceConnection {
        const state = try std.testing.allocator.create(
            BlockingResourceConnection,
        );
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(
        self: *BlockingResourceConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = buffer;
        _ = timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.reading = true;
        self.condition.broadcast();
        while (!self.closed) self.condition.wait(&self.mutex);
        return error.ConnectionClosed;
    }

    pub fn writeAll(
        self: *BlockingResourceConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = bytes;
        _ = timeout_ms;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.ConnectionClosed;
        self.writes += 1;
    }

    pub fn close(self: *BlockingResourceConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.condition.broadcast();
    }

    fn waitUntilReading(self: *BlockingResourceConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.reading) self.condition.wait(&self.mutex);
    }

    fn writeCount(self: *BlockingResourceConnection) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.writes;
    }

    pub fn deinit(self: *BlockingResourceConnection) void {
        const allocator = self.allocator;
        self.close();
        allocator.destroy(self);
    }
};

const SplitBudgetConnection = struct {
    allocator: std.mem.Allocator,
    write_calls: usize = 0,
    response_sent: bool = false,
    read_timeout_ms: ?u32 = null,

    fn create() !*SplitBudgetConnection {
        const state = try std.testing.allocator.create(
            SplitBudgetConnection,
        );
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(
        self: *SplitBudgetConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        self.read_timeout_ms = timeout_ms;
        const response_delay_ms: u32 = 30;
        if (timeout_ms) |remaining| {
            if (remaining <= response_delay_ms) {
                std.Thread.sleep(
                    @as(u64, remaining) * std.time.ns_per_ms,
                );
                return error.Timeout;
            }
        }
        std.Thread.sleep(response_delay_ms * std.time.ns_per_ms);
        if (self.response_sent) return error.ConnectionClosed;
        const response =
            "{\"protocol\":\"cmux.protocol/2\",\"type\":\"response\"," ++
            "\"id\":\"zig-request-1\",\"ok\":true,\"result\":{}}\n";
        const count = @min(buffer.len, response.len);
        @memcpy(buffer[0..count], response[0..count]);
        self.response_sent = true;
        return count;
    }

    pub fn writeAll(
        self: *SplitBudgetConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = bytes;
        _ = timeout_ms;
        self.write_calls += 1;
        if (self.write_calls == 1) {
            std.Thread.sleep(35 * std.time.ns_per_ms);
        }
    }

    pub fn close(self: *SplitBudgetConnection) void {
        _ = self;
    }

    pub fn deinit(self: *SplitBudgetConnection) void {
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const FullDispatchDeadlineConnection = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    write_calls: usize = 0,
    closed: bool = false,

    fn create() !*FullDispatchDeadlineConnection {
        const state = try std.testing.allocator.create(
            FullDispatchDeadlineConnection,
        );
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(
        self: *FullDispatchDeadlineConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = self;
        _ = buffer;
        _ = timeout_ms;
        return error.UnexpectedRead;
    }

    pub fn writeAll(
        self: *FullDispatchDeadlineConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        try self.output.appendSlice(self.allocator, bytes);
        self.write_calls += 1;
        if (self.write_calls == 2) {
            const delay_ms = @as(u64, timeout_ms orelse 10) + 2;
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
    }

    pub fn close(self: *FullDispatchDeadlineConnection) void {
        self.closed = true;
    }

    pub fn deinit(self: *FullDispatchDeadlineConnection) void {
        const allocator = self.allocator;
        self.output.deinit(allocator);
        allocator.destroy(self);
    }
};

const PayloadBoundaryMode = enum {
    complete_then_deadline,
    fail_before_payload,
    partial_then_timeout,
    complete_then_custom_payload_failure,
    complete_then_custom_newline_failure,
    partial_then_custom_failure,
    complete_then_custom_read_failure,
};

const PayloadBoundaryConnection = struct {
    allocator: std.mem.Allocator,
    mode: PayloadBoundaryMode,
    output: std.ArrayList(u8) = .empty,
    attempted_payload_bytes: usize = 0,
    write_calls: usize = 0,
    closed: bool = false,

    fn create(mode: PayloadBoundaryMode) !*PayloadBoundaryConnection {
        const state = try std.testing.allocator.create(
            PayloadBoundaryConnection,
        );
        state.* = .{
            .allocator = std.testing.allocator,
            .mode = mode,
        };
        return state;
    }

    pub fn read(
        self: *PayloadBoundaryConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = buffer;
        _ = timeout_ms;
        if (self.mode == .complete_then_custom_read_failure) {
            return error.InjectedTransportFailure;
        }
        return error.UnexpectedRead;
    }

    pub fn writeAll(
        self: *PayloadBoundaryConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        self.write_calls += 1;
        if (self.write_calls == 1) {
            self.attempted_payload_bytes = bytes.len;
        }
        switch (self.mode) {
            .complete_then_deadline => {
                try self.output.appendSlice(self.allocator, bytes);
                const delay_ms = @as(u64, timeout_ms orelse 10) + 2;
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            },
            .fail_before_payload => return error.InjectedTransportFailure,
            .partial_then_timeout => {
                const partial_len = @max(@as(usize, 1), bytes.len / 2);
                try self.output.appendSlice(
                    self.allocator,
                    bytes[0..partial_len],
                );
                return error.Timeout;
            },
            .complete_then_custom_payload_failure => {
                try self.output.appendSlice(self.allocator, bytes);
                return error.InjectedTransportFailure;
            },
            .complete_then_custom_newline_failure => {
                if (self.write_calls == 2) {
                    return error.InjectedTransportFailure;
                }
                try self.output.appendSlice(self.allocator, bytes);
            },
            .partial_then_custom_failure => {
                const partial_len = @max(@as(usize, 1), bytes.len / 2);
                try self.output.appendSlice(
                    self.allocator,
                    bytes[0..partial_len],
                );
                return error.InjectedTransportFailure;
            },
            .complete_then_custom_read_failure => {
                try self.output.appendSlice(self.allocator, bytes);
            },
        }
    }

    pub fn close(self: *PayloadBoundaryConnection) void {
        self.closed = true;
    }

    pub fn deinit(self: *PayloadBoundaryConnection) void {
        const allocator = self.allocator;
        self.output.deinit(allocator);
        allocator.destroy(self);
    }
};

const AdmissionWorker = struct {
    client: *Client,
    timeout_ms: u32,
    acquired: bool = false,
    failure: ?anyerror = null,

    fn run(self: *AdmissionWorker) void {
        var deadline = TimeoutDeadline.start(self.timeout_ms) catch |failure| {
            self.failure = failure;
            return;
        };
        self.client.acquireRequest(&deadline) catch |failure| {
            self.failure = failure;
            return;
        };
        self.acquired = true;
        self.client.releaseRequest();
    }
};

const AtomicResourceConnection = struct {
    allocator: std.mem.Allocator,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn create() !*AtomicResourceConnection {
        const state = try std.testing.allocator.create(
            AtomicResourceConnection,
        );
        state.* = .{ .allocator = std.testing.allocator };
        return state;
    }

    pub fn read(
        self: *AtomicResourceConnection,
        buffer: []u8,
        timeout_ms: ?u32,
    ) !usize {
        _ = buffer;
        _ = timeout_ms;
        if (self.closed.load(.acquire)) return error.ConnectionClosed;
        return error.UnexpectedRead;
    }

    pub fn writeAll(
        self: *AtomicResourceConnection,
        bytes: []const u8,
        timeout_ms: ?u32,
    ) !void {
        _ = bytes;
        _ = timeout_ms;
        if (self.closed.load(.acquire)) return error.ConnectionClosed;
        _ = self.write_calls.fetchAdd(1, .monotonic);
    }

    pub fn close(self: *AtomicResourceConnection) void {
        self.closed.store(true, .release);
    }

    pub fn deinit(self: *AtomicResourceConnection) void {
        const allocator = self.allocator;
        self.close();
        allocator.destroy(self);
    }
};

fn waitForRequestWaiters(
    client: *Client,
    expected: usize,
    timeout_ms: u32,
) !void {
    var timer = try std.time.Timer.start();
    while (true) {
        client.request_admission_mutex.lock();
        const count = client.request_waiters;
        client.request_admission_mutex.unlock();
        if (count >= expected) return;
        if (timer.read() >= @as(u64, timeout_ms) * std.time.ns_per_ms) {
            return error.Timeout;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

const StreamFactoryState = struct {
    shared: *FakeShared,
    open_delay_ms: u32 = 0,
    open_calls: usize = 0,
    open_timeout_ms: ?u32 = null,

    fn open(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        timeout_ms: ?u32,
    ) !raw.transport.Connection {
        const self: *StreamFactoryState = @ptrCast(@alignCast(context));
        self.open_calls += 1;
        self.open_timeout_ms = timeout_ms;
        if (self.open_delay_ms > 0) {
            std.Thread.sleep(
                @as(u64, self.open_delay_ms) * std.time.ns_per_ms,
            );
        }
        return fakeConnection(allocator, self.shared);
    }
};

fn hasFacadeDeclaration(
    comptime owner: FacadeOwner,
    comptime method: []const u8,
) bool {
    const Owner = switch (owner) {
        .client => Client,
        .machine => Machine,
        .session => Session,
        .workspace => Workspace,
        .screen => Screen,
        .pane => Pane,
        .tab => Tab,
        .terminal => Terminal,
        .browser => Browser,
        .connected_client => ConnectedClient,
        .pairing_request => PairingRequest,
        .frontend_projection => FrontendProjection,
        .sidebar_view => SidebarView,
        .session_stream => SessionEventStream,
        .terminal_stream => TerminalAttachmentStream,
        .browser_stream => BrowserAttachmentStream,
    };
    if (!@hasDecl(Owner, method)) return false;
    _ = @field(Owner, method);
    return true;
}

fn methodAllowed(
    comptime allowed: []const []const u8,
    comptime method: []const u8,
) bool {
    inline for (allowed) |candidate| {
        if (std.mem.eql(u8, candidate, method)) return true;
    }
    return false;
}

fn expectHandleCapabilities(
    comptime Facade: type,
    comptime allowed: []const []const u8,
) !void {
    try std.testing.expect(@hasDecl(Facade, "selector"));
    try std.testing.expect(@hasDecl(Facade, "id"));
    inline for (std.meta.fields(Operation)) |field| {
        const operation: Operation = @enumFromInt(field.value);
        const method = comptime operation.facadeBinding().method;
        try std.testing.expectEqual(
            comptime methodAllowed(allowed, method),
            @hasDecl(Facade, method),
        );
    }
    const conveniences = .{
        "session",
        "workspace",
        "screen",
        "pane",
        "tab",
        "terminal",
        "browser",
        "connectedClient",
        "pairingRequest",
        "frontendProjection",
        "sidebarView",
        "notification",
        "agent",
        "clearName",
        "writeText",
        "events",
        "attachTerminal",
        "attachBrowser",
        "rendererGrant",
    };
    inline for (conveniences) |method| {
        try std.testing.expectEqual(
            comptime methodAllowed(allowed, method),
            @hasDecl(Facade, method),
        );
    }
}

fn expectStreamCapabilities(
    comptime Stream: type,
    comptime allowed: []const []const u8,
) !void {
    inline for (.{ "deinit", "next", "cancel", "end" }) |method| {
        try std.testing.expect(@hasDecl(Stream, method));
    }
    inline for (.{
        "resizeTerminalViewer",
        "releaseTerminalViewer",
        "resizeBrowserViewer",
        "releaseBrowserViewer",
    }) |method| {
        try std.testing.expectEqual(
            comptime methodAllowed(allowed, method),
            @hasDecl(Stream, method),
        );
    }
}

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

test "decimal wire values are canonical strings only" {
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try decimalU64(.{ .string = "18446744073709551615" }),
    );
    try std.testing.expectError(
        error.ExpectedDecimalString,
        decimalU64(.{ .integer = 7 }),
    );
    try std.testing.expectError(
        error.InvalidDecimalString,
        decimalU64(.{ .string = "07" }),
    );
    try std.testing.expectError(
        error.InvalidDecimalString,
        decimalU64(.{ .string = "+7" }),
    );
    try std.testing.expectError(
        error.Overflow,
        decimalU64(.{ .string = "18446744073709551616" }),
    );
    try std.testing.expectEqual(
        @as(u16, 7),
        try unsignedValue(u16, .{ .integer = 7 }, 0),
    );
    try std.testing.expectError(
        error.ExpectedUnsignedInteger,
        unsignedValue(u16, .{ .string = "7" }, 0),
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
}

test "layout undo requires and forwards confirmation capability" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const screen = client.screen(try ScreenId.parse(
        "screen_55555555555555555555555555555555",
    ));
    try std.testing.expectError(
        error.MissingConfirmationToken,
        screen.undoLayout(
            .{ .confirm_close = true },
            MutationOptions.random(),
        ),
    );
    try std.testing.expectError(
        error.InvalidConfirmationToken,
        screen.undoLayout(
            .{ .confirmation_token = "" },
            MutationOptions.random(),
        ),
    );
    var too_long: [129]u8 = undefined;
    @memset(&too_long, 'x');
    try std.testing.expectError(
        error.InvalidConfirmationToken,
        screen.undoLayout(
            .{ .confirmation_token = &too_long },
            MutationOptions.random(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), shared.output.items.len);

    var result = try screen.undoLayout(
        .{
            .confirm_close = true,
            .confirmation_token = "confirm-3",
        },
        (MutationOptions.random()).expecting(3),
    );
    defer result.deinit();
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"confirm_close\":true",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"confirmation_token\":\"confirm-3\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"expected_revision\":\"3\"",
        ) != null,
    );
}

test "every catalog operation reaches a typed public facade" {
    @setEvalBranchQuota(20_000);
    const operation_fields = std.meta.fields(Operation);
    try std.testing.expectEqual(@as(usize, 114), operation_fields.len);
    inline for (operation_fields, 0..) |field, index| {
        const operation: Operation = @enumFromInt(field.value);
        const binding = comptime operation.facadeBinding();
        try std.testing.expect(
            hasFacadeDeclaration(binding.owner, binding.method),
        );
        inline for (operation_fields[0..index]) |previous_field| {
            const previous: Operation = @enumFromInt(
                previous_field.value,
            );
            try std.testing.expect(!std.mem.eql(
                u8,
                operation.wireName(),
                previous.wireName(),
            ));
        }
    }
}

test "public facades expose only valid resource and stream capabilities" {
    @setEvalBranchQuota(200_000);
    try expectHandleCapabilities(Machine, &.{
        "session",
        "refresh",
        "listSessions",
        "openSession",
    });
    try expectHandleCapabilities(Session, &.{
        "workspace",
        "terminal",
        "connectedClient",
        "pairingRequest",
        "frontendProjection",
        "sidebarView",
        "refresh",
        "listWorkspaces",
        "listScreens",
        "listPanes",
        "listTerminals",
        "listBrowsers",
        "listClients",
        "listPairingRequests",
        "listNotifications",
        "listAgents",
        "createNotification",
        "reportAgent",
        "ensureSidebarView",
        "ping",
        "fullSnapshot",
        "resolveCreation",
        "shutdown",
        "close",
        "reloadConfig",
        "updateTerminalDefaults",
        "setWindowTitle",
        "clearWindowTitle",
        "createWorkspace",
        "events",
        "eventsFrom",
        "journal",
    });
    try expectHandleCapabilities(Workspace, &.{
        "screen",
        "refresh",
        "listScreens",
        "listPanes",
        "listTerminals",
        "listBrowsers",
        "close",
        "rename",
        "clearName",
        "moveWorkspace",
        "focusWorkspace",
        "applyLayout",
        "createScreen",
        "run",
    });
    try expectHandleCapabilities(Screen, &.{
        "pane",
        "refresh",
        "listPanes",
        "listTerminals",
        "listBrowsers",
        "close",
        "rename",
        "clearName",
        "focusScreen",
        "exportLayout",
        "undoLayout",
        "createPane",
    });
    try expectHandleCapabilities(Pane, &.{
        "tab",
        "refresh",
        "listTabs",
        "listTerminals",
        "listBrowsers",
        "close",
        "rename",
        "clearName",
        "splitPane",
        "focusPane",
        "focusDirection",
        "neighbor",
        "swapPane",
        "zoomPane",
        "setSplitRatio",
        "setViewportWidth",
        "run",
        "createTerminalTab",
        "createBrowserTab",
    });
    try expectHandleCapabilities(Tab, &.{
        "terminal",
        "browser",
        "refresh",
        "listTerminals",
        "listBrowsers",
        "close",
        "rename",
        "clearName",
        "focusTab",
        "moveTab",
    });
    try expectHandleCapabilities(Terminal, &.{
        "refresh",
        "close",
        "readScreen",
        "readState",
        "readHistory",
        "copy",
        "processInfo",
        "waitFor",
        "waitForExit",
        "clearHistory",
        "writeText",
        "writeBytes",
        "sendKeys",
        "sendMouse",
        "setInputFocus",
        "moveTerminal",
        "projectTerminal",
        "scroll",
        "attachTerminal",
        "attachTerminalWith",
        "rendererGrant",
        "rendererGrantWith",
    });
    try expectHandleCapabilities(Browser, &.{
        "refresh",
        "close",
        "navigate",
        "browserBack",
        "browserForward",
        "reloadBrowser",
        "activateBrowser",
        "sendBrowserKey",
        "sendBrowserText",
        "sendBrowserMouse",
        "sendBrowserWheel",
        "attachBrowser",
        "attachBrowserWith",
    });
    try expectHandleCapabilities(ConnectedClient, &.{
        "refresh",
        "updateMetadata",
        "setCellPixels",
        "setSizing",
        "releaseSizing",
        "detachClient",
    });
    try expectHandleCapabilities(PairingRequest, &.{
        "resolvePairing",
    });
    try expectHandleCapabilities(FrontendProjection, &.{
        "refresh",
        "putProjection",
    });
    try expectHandleCapabilities(SidebarView, &.{
        "refresh",
        "attachSidebar",
        "sendSidebarInput",
        "resizeSidebar",
        "reloadSidebar",
    });

    try expectStreamCapabilities(SessionEventStream, &.{});
    try expectStreamCapabilities(SessionJournalStream, &.{});
    try expectStreamCapabilities(SidebarViewStream, &.{});
    try expectStreamCapabilities(TerminalAttachmentStream, &.{
        "resizeTerminalViewer",
        "releaseTerminalViewer",
    });
    try expectStreamCapabilities(BrowserAttachmentStream, &.{
        "resizeBrowserViewer",
        "releaseBrowserViewer",
    });
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

test "browser pointer inputs require and encode the exact frame token" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const browser_id = try BrowserId.parse(
        "browser_0123456789abcdef0123456789abcdef",
    );
    const pointer_frame_seq = std.math.maxInt(u64);

    var mouse_result = try client.browser(browser_id).sendBrowserMouse(
        .{
            .kind = .move,
            .x_px = 12,
            .y_px = 34,
            .pointer_frame_seq = pointer_frame_seq,
        },
        try MutationOptions.withKey("browser-mouse-frame-token"),
    );
    defer mouse_result.deinit();
    var wheel_result = try client.browser(browser_id).sendBrowserWheel(
        .{
            .delta_x = -1.5,
            .delta_y = 2.25,
            .pointer_frame_seq = pointer_frame_seq,
            .x_px = 12,
            .y_px = 34,
        },
        try MutationOptions.withKey("browser-wheel-frame-token"),
    );
    defer wheel_result.deinit();

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"operation\":\"browser.input.mouse\"",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"operation\":\"browser.input.wheel\"",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(
            u8,
            shared.output.items,
            "\"pointer_frame_seq\":\"18446744073709551615\"",
        ),
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"pointer_frame_seq\":18446744073709551615",
        ) == null,
    );
}

test "mutation keys use independent cryptographic 128-bit values" {
    const first = MutationOptions.random();
    const second = MutationOptions.random();
    try std.testing.expectEqual(@as(usize, 36), first.key().len);
    try std.testing.expectEqual(@as(usize, 36), second.key().len);
    try std.testing.expect(!std.mem.eql(u8, first.key(), second.key()));
}

test "idempotency keys match the durable identifier contract" {
    var exact_limit: [128]u8 = undefined;
    for (0..64) |index| {
        exact_limit[index * 2] = 0xC3;
        exact_limit[index * 2 + 1] = 0xA9;
    }
    var over_limit: [130]u8 = undefined;
    @memcpy(over_limit[0..128], &exact_limit);
    over_limit[128] = 0xC3;
    over_limit[129] = 0xA9;
    const invalid_utf8 = [_]u8{ 'k', 'e', 'y', 0xFF };
    for ([_][]const u8{
        "",
        " \u{00a0}\u{3000}",
        "key\ncontrol",
        "key\u{0085}control",
        &over_limit,
        &invalid_utf8,
    }) |value| {
        try std.testing.expectError(
            error.InvalidIdempotencyKey,
            MutationOptions.withKey(value),
        );
    }
    for ([_][]const u8{
        " key ",
        "\u{feff}",
        &exact_limit,
    }) |value| {
        const key = try MutationOptions.withKey(value);
        try std.testing.expectEqualSlices(u8, value, key.key());
    }
}

test "mutation send revalidates directly constructed options" {
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

    var whitespace: MutationOptions = .{ .len = 1 };
    whitespace.bytes[0] = ' ';
    try std.testing.expectError(
        error.InvalidIdempotencyKey,
        client.workspace(id).rename("renamed", whitespace),
    );
    var over_limit: MutationOptions = .{ .len = 129 };
    @memset(&over_limit.bytes, 'x');
    try std.testing.expectError(
        error.InvalidIdempotencyKey,
        client.workspace(id).rename("renamed", over_limit),
    );
    try std.testing.expectEqual(@as(usize, 0), shared.output.items.len);
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
        "{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\"," ++
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
        "{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\"," ++
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

test "workspace create writes exact route and correlation key bytes" {
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
        .{
            .name = "sdk-tests",
            .initial_content = .empty,
            .correlation_key = "create:key/01",
        },
        (try MutationOptions.withKey("session-selector-key")).expecting(7),
    );
    created.deinit();
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\"," ++
            "\"id\":\"zig-request-1\",\"operation\":" ++
            "\"workspace.create\",\"params\":{" ++
            "\"machine\":\"current\",\"session\":\"name:release\"," ++
            "\"name\":\"sdk-tests\",\"initial_content\":\"empty\"," ++
            "\"correlation_key\":\"create:key/01\"," ++
            "\"expected_revision\":\"7\"}," ++
            "\"idempotency_key\":\"session-selector-key\"}\n",
        shared.output.items,
    );
}

test "session terminal emits only machine session and terminal selectors" {
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
    var result = try client
        .session(.{ .name = "release" })
        .terminal(terminal_id)
        .waitForExit(5000);
    defer result.deinit();
    switch (result.value) {
        .pending => |pending| {
            try std.testing.expectEqual(terminal_id, pending.terminal_id);
            try std.testing.expectEqual(
                TerminalLifecycle.running,
                pending.lifecycle,
            );
            try std.testing.expectEqual(@as(u64, 11), pending.revision);
        },
        .exited => return error.ExpectedPending,
    }
    try std.testing.expectEqualStrings(
        "{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\"," ++
            "\"id\":\"zig-request-1\",\"operation\":" ++
            "\"terminal.wait_exit\",\"params\":{" ++
            "\"machine\":\"current\",\"session\":\"name:release\"," ++
            "\"terminal\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"timeout_ms\":\"5000\"}}\n",
        shared.output.items,
    );
}

test "timed out wait exit cancels once and reuses its control connection" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .abandoned_wait_cancel_true,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 2,
    });
    defer client.deinit();
    const session_id = try SessionId.parse(
        "session_0123456789abcdef0123456789abcdef",
    );
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.Timeout,
        client.session(session_id).terminal(terminal_id).waitForExit(null),
    );
    try std.testing.expect(!client.isClosed());
    try std.testing.expect(shared.request_cancel_route_ok);
    try std.testing.expectEqual(
        @as(usize, 1),
        shared.request_cancel_count,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        client.inbound.items.len,
    );

    var ping = try client.session(session_id).ping();
    defer ping.deinit();
    try std.testing.expect(ping.value.alive);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            shared.output.items,
            "\"operation\":\"request.cancel\"",
        ),
    );
}

test "one request deadline covers admission send and receive" {
    const split = try SplitBudgetConnection.create();
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(split),
        .{ .timeout_ms = 50 },
    );
    defer client.deinit();
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.Timeout,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expect(split.read_timeout_ms != null);
    try std.testing.expect(split.read_timeout_ms.? < 30);
}

test "deadline before first write leaves the connection reusable" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 1_000,
    });
    defer client.deinit();
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    var deadline = try TimeoutDeadline.start(20);
    var dispatch: RequestDispatch = .payload_complete;
    try client.acquireRequest(&deadline);
    {
        defer client.releaseRequest();
        client.mutex.lock();
        defer client.mutex.unlock();
        std.Thread.sleep(25 * std.time.ns_per_ms);
        try std.testing.expectError(
            error.Timeout,
            client.sendRequestWithDeadline(
                "expired-before-write",
                .machine_list,
                .{ .object = params },
                null,
                &deadline,
                &dispatch,
            ),
        );
    }

    try std.testing.expectEqual(RequestDispatch.not_dispatched, dispatch);
    try std.testing.expect(!client.isClosed());
    try std.testing.expectEqual(@as(usize, 0), shared.write_calls);

    var result = try client.read(.machine_list, .{ .object = params });
    defer result.deinit();
    try std.testing.expect(!client.isClosed());
    try std.testing.expectEqual(@as(usize, 2), shared.write_calls);
}

test "fully dispatched mutation timeout preserves uncertainty" {
    const dispatched = try FullDispatchDeadlineConnection.create();
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(dispatched),
        .{ .timeout_ms = 10 },
    );
    defer client.deinit();
    const workspace_id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.MutationTransportUncertain,
        client.workspace(workspace_id).rename(
            "fully-dispatched",
            try MutationOptions.withKey("full-dispatch-timeout-key"),
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), dispatched.write_calls);
    try std.testing.expect(std.mem.endsWith(u8, dispatched.output.items, "\n"));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            dispatched.output.items,
            "\"operation\":\"workspace.rename\"",
        ),
    );
    const uncertainty = client.lastMutationTransportUncertain().?;
    try std.testing.expectEqual(
        MutationTransportCause.timeout,
        uncertainty.cause,
    );
    try std.testing.expectEqualStrings(
        "full-dispatch-timeout-key",
        uncertainty.idempotency_key,
    );
    try std.testing.expect(dispatched.closed);
}

test "complete mutation payload without newline is uncertain" {
    const payload = try PayloadBoundaryConnection.create(
        .complete_then_deadline,
    );
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(payload),
        .{ .timeout_ms = 10 },
    );
    defer client.deinit();
    const workspace_id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.MutationTransportUncertain,
        client.workspace(workspace_id).rename(
            "payload-complete",
            try MutationOptions.withKey("payload-complete-key"),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), payload.write_calls);
    try std.testing.expectEqual(
        payload.attempted_payload_bytes,
        payload.output.items.len,
    );
    try std.testing.expect(
        !std.mem.endsWith(u8, payload.output.items, "\n"),
    );
    const uncertainty = client.lastMutationTransportUncertain().?;
    try std.testing.expectEqual(
        MutationTransportCause.timeout,
        uncertainty.cause,
    );
    try std.testing.expectEqualStrings(
        "payload-complete-key",
        uncertainty.idempotency_key,
    );
    try std.testing.expect(payload.closed);
}

test "partial mutation payload timeout is conservatively uncertain" {
    const payload = try PayloadBoundaryConnection.create(
        .partial_then_timeout,
    );
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(payload),
        .{ .timeout_ms = 1_000 },
    );
    defer client.deinit();
    const workspace_id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.MutationTransportUncertain,
        client.workspace(workspace_id).rename(
            "payload-partial",
            try MutationOptions.withKey("payload-partial-key"),
        ),
    );
    try std.testing.expectEqual(
        MutationTransportCause.timeout,
        client.lastMutationTransportUncertain().?.cause,
    );
    try std.testing.expectEqual(@as(usize, 1), payload.write_calls);
    try std.testing.expect(
        payload.output.items.len < payload.attempted_payload_bytes,
    );
    try std.testing.expect(
        !std.mem.endsWith(u8, payload.output.items, "\n"),
    );
    try std.testing.expect(payload.closed);
}

test "nonstandard failures after a complete mutation payload are uncertain" {
    for ([_]PayloadBoundaryMode{
        .complete_then_custom_newline_failure,
        .complete_then_custom_read_failure,
    }) |mode| {
        const payload = try PayloadBoundaryConnection.create(mode);
        var client = Client.init(
            std.testing.allocator,
            raw.transport.Connection.from(payload),
            .{ .timeout_ms = 1_000 },
        );
        defer client.deinit();
        const workspace_id = try WorkspaceId.parse(
            "ws_0123456789abcdef0123456789abcdef",
        );

        try std.testing.expectError(
            error.MutationTransportUncertain,
            client.workspace(workspace_id).rename(
                "custom-transport-failure",
                try MutationOptions.withKey("custom-transport-key"),
            ),
        );
        const uncertainty = client.lastMutationTransportUncertain().?;
        try std.testing.expectEqual(
            Operation.workspace_rename,
            uncertainty.operation,
        );
        try std.testing.expectEqualStrings(
            "custom-transport-key",
            uncertainty.idempotency_key,
        );
        try std.testing.expectEqual(
            MutationTransportCause.other,
            uncertainty.cause,
        );
        try std.testing.expectEqual(@as(usize, 2), payload.write_calls);
        try std.testing.expect(payload.closed);
    }
}

test "payload write errors are conservatively uncertain" {
    for ([_]PayloadBoundaryMode{
        .fail_before_payload,
        .partial_then_custom_failure,
        .complete_then_custom_payload_failure,
    }) |mode| {
        const payload = try PayloadBoundaryConnection.create(mode);
        var client = Client.init(
            std.testing.allocator,
            raw.transport.Connection.from(payload),
            .{ .timeout_ms = 1_000 },
        );
        defer client.deinit();
        const workspace_id = try WorkspaceId.parse(
            "ws_0123456789abcdef0123456789abcdef",
        );

        try std.testing.expectError(
            error.MutationTransportUncertain,
            client.workspace(workspace_id).rename(
                "custom-transport-failure",
                try MutationOptions.withKey("custom-transport-key"),
            ),
        );
        try std.testing.expectEqual(
            MutationTransportCause.other,
            client.lastMutationTransportUncertain().?.cause,
        );
        try std.testing.expectEqual(@as(usize, 1), payload.write_calls);
        switch (mode) {
            .fail_before_payload => try std.testing.expectEqual(
                @as(usize, 0),
                payload.output.items.len,
            ),
            .partial_then_custom_failure => try std.testing.expect(
                payload.output.items.len < payload.attempted_payload_bytes,
            ),
            .complete_then_custom_payload_failure => try std.testing.expectEqual(
                payload.attempted_payload_bytes,
                payload.output.items.len,
            ),
            else => unreachable,
        }
        try std.testing.expect(payload.closed);
    }
}

test "non-mutation post-payload failure retains its original error" {
    const payload = try PayloadBoundaryConnection.create(
        .complete_then_custom_read_failure,
    );
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(payload),
        .{ .timeout_ms = 1_000 },
    );
    defer client.deinit();
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.InjectedTransportFailure,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expect(
        client.lastMutationTransportUncertain() == null,
    );
    try std.testing.expectEqual(@as(usize, 2), payload.write_calls);
    try std.testing.expect(payload.closed);
    const writes_after_failure = payload.write_calls;
    try std.testing.expectError(
        error.ConnectionClosed,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expectEqual(
        writes_after_failure,
        payload.write_calls,
    );
}

test "oversized inbound frame closes before connection reuse" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .limits = .{ .max_frame_bytes = 4 },
    });
    defer client.deinit();
    try client.inbound.appendSlice(std.testing.allocator, "12345");
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.FrameTooLarge,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expect(shared.closed);
    const writes_after_failure = shared.write_calls;
    try std.testing.expectError(
        error.ConnectionClosed,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expectEqual(writes_after_failure, shared.write_calls);
}

test "malformed inbound JSON closes before connection reuse" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    try client.inbound.appendSlice(
        std.testing.allocator,
        "not-json\n",
    );
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.SyntaxError,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expect(shared.closed);
    const writes_after_failure = shared.write_calls;
    try std.testing.expectError(
        error.ConnectionClosed,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expectEqual(writes_after_failure, shared.write_calls);
}

test "invalid response envelope closes before connection reuse" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    try client.inbound.appendSlice(
        std.testing.allocator,
        "{\"type\":\"response\",\"id\":\"zig-request-1\"," ++
            "\"ok\":true,\"result\":{}}\n",
    );
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.InvalidProtocolEnvelope,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expect(shared.closed);
    const writes_after_failure = shared.write_calls;
    try std.testing.expectError(
        error.ConnectionClosed,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expectEqual(writes_after_failure, shared.write_calls);
}

test "invalid mutation response records uncertainty and closes" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    try client.inbound.appendSlice(
        std.testing.allocator,
        "{\"type\":\"response\",\"id\":\"zig-request-1\"," ++
            "\"ok\":true,\"result\":{}}\n",
    );
    const workspace_id = try WorkspaceId.parse(
        "ws_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.MutationTransportUncertain,
        client.workspace(workspace_id).rename(
            "invalid-response",
            try MutationOptions.withKey("invalid-response-key"),
        ),
    );
    const uncertainty = client.lastMutationTransportUncertain().?;
    try std.testing.expectEqual(
        MutationTransportCause.other,
        uncertainty.cause,
    );
    try std.testing.expectEqualStrings(
        "invalid-response-key",
        uncertainty.idempotency_key,
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expect(shared.closed);
}

test "mutation payload write failures are conservatively uncertain" {
    for ([_]usize{ 1, 2 }) |fail_write_call| {
        var shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .fail_write_call = fail_write_call,
        };
        defer shared.deinit();
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
                "not-dispatched",
                try MutationOptions.withKey("pre-dispatch-failure-key"),
            ),
        );
        try std.testing.expectEqual(
            MutationTransportCause.other,
            client.lastMutationTransportUncertain().?.cause,
        );
    }
}

test "expired admission successor wakes three queued waiters" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    client.request_admission_mutex.lock();
    client.request_active = true;
    client.request_admission_mutex.unlock();

    var workers = [_]AdmissionWorker{
        .{ .client = &client, .timeout_ms = 1_000 },
        .{ .client = &client, .timeout_ms = 1_000 },
        .{ .client = &client, .timeout_ms = 1_000 },
    };
    var threads: [workers.len]std.Thread = undefined;
    var thread_count: usize = 0;
    var threads_joined = false;
    defer {
        if (!threads_joined) {
            for (threads[0..thread_count]) |*thread| thread.join();
        }
    }
    for (&workers, 0..) |*worker, index| {
        threads[index] = try std.Thread.spawn(
            .{},
            AdmissionWorker.run,
            .{worker},
        );
        thread_count += 1;
    }
    try waitForRequestWaiters(&client, workers.len, 250);

    // Model the first signaled successor reaching the idle permit only after
    // its deadline. The expired claimant must pass the wakeup onward.
    var expired = try TimeoutDeadline.start(1);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    client.request_admission_mutex.lock();
    client.request_active = false;
    client.request_admission_mutex.unlock();
    try std.testing.expectError(
        error.Timeout,
        client.acquireRequest(&expired),
    );

    for (&threads) |*thread| thread.join();
    threads_joined = true;
    for (workers) |worker| {
        try std.testing.expect(worker.acquired);
        try std.testing.expect(worker.failure == null);
    }
}

test "queued request admission expires without writing a frame" {
    const blocking = try BlockingResourceConnection.create();
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(blocking),
        .{ .timeout_ms = 20 },
    );
    defer client.deinit();
    const Worker = struct {
        client: *Client,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var params = raw.wire.Object.init(std.testing.allocator);
            defer params.deinit();
            var result = self.client.read(
                .machine_list,
                .{ .object = params },
            ) catch |failure| {
                self.failure = failure;
                return;
            };
            result.deinit();
        }
    };
    var worker = Worker{ .client = &client };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    blocking.waitUntilReading();

    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();
    try std.testing.expectError(
        error.Timeout,
        client.read(.machine_list, .{ .object = params }),
    );
    try std.testing.expectEqual(@as(usize, 2), blocking.writeCount());

    client.close();
    thread.join();
    try std.testing.expectEqual(
        error.ConnectionClosed,
        worker.failure orelse return error.MissingWorkerFailure,
    );
}

test "close racing fresh request admission is synchronized" {
    const transport = try AtomicResourceConnection.create();
    var client = Client.init(
        std.testing.allocator,
        raw.transport.Connection.from(transport),
        .{ .timeout_ms = 1_000 },
    );
    defer client.deinit();
    client.request_admission_mutex.lock();
    client.request_active = true;
    client.request_admission_mutex.unlock();
    var worker = AdmissionWorker{
        .client = &client,
        .timeout_ms = 50,
    };
    const thread = try std.Thread.spawn(
        .{},
        AdmissionWorker.run,
        .{&worker},
    );

    try waitForRequestWaiters(&client, 1, 250);
    client.close();
    thread.join();

    try std.testing.expectEqual(
        error.ConnectionClosed,
        worker.failure orelse return error.MissingWorkerFailure,
    );
    try std.testing.expect(!worker.acquired);
    try std.testing.expectEqual(
        @as(usize, 0),
        transport.write_calls.load(.acquire),
    );
}

test "wait cancel false drains the raced response before reuse" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .abandoned_wait_cancel_false,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 2,
    });
    defer client.deinit();
    const session_id = try SessionId.parse(
        "session_0123456789abcdef0123456789abcdef",
    );
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.Timeout,
        client
            .session(session_id)
            .terminal(terminal_id)
            .waitFor("never", null),
    );
    try std.testing.expect(!client.isClosed());
    try std.testing.expect(shared.request_cancel_route_ok);
    try std.testing.expectEqual(
        @as(usize, 1),
        shared.request_cancel_count,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        client.inbound.items.len,
    );

    var ping = try client.session(session_id).ping();
    defer ping.deinit();
    try std.testing.expect(ping.value.alive);
}

test "wait cancel false rejects a malformed raced result" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .abandoned_wait_malformed_target,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 2,
    });
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.Timeout,
        client
            .session(.current)
            .terminal(terminal_id)
            .waitFor("never", null),
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expectEqual(
        @as(usize, 1),
        shared.request_cancel_count,
    );
}

test "malformed wait cleanup preserves timeout and fail closes once" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .abandoned_wait_malformed_cancel,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 2,
    });
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.Timeout,
        client
            .session(.current)
            .terminal(terminal_id)
            .waitFor("never", null),
    );
    try std.testing.expect(client.isClosed());
    try std.testing.expect(shared.request_cancel_route_ok);
    try std.testing.expectEqual(
        @as(usize, 1),
        shared.request_cancel_count,
    );
    try std.testing.expectError(
        error.ConnectionClosed,
        client
            .session(.current)
            .terminal(terminal_id)
            .waitFor("again", null),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        shared.request_cancel_count,
    );
}

test "wait timeout before dispatch sends no cancellation" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .abandoned_wait_cancel_true,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 0,
    });
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );

    try std.testing.expectError(
        error.Timeout,
        client
            .session(.current)
            .terminal(terminal_id)
            .waitForExit(null),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        shared.output.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        shared.request_cancel_count,
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
    try std.testing.expectEqualStrings(
        "/tmp/subshell",
        process.value.foreground_cwd.?,
    );
    try std.testing.expectEqual(@as(u32, 125), process.value.children[1]);

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

test "terminal lifecycle and durable exit constraints are strict" {
    var decoded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded_arena.deinit();
    var running = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_ids\":[\"tab_77777777777777777777777777777777\"]," ++
            "\"title\":\"shell\",\"cols\":120,\"rows\":40," ++
            "\"running\":true,\"lifecycle\":\"running\"," ++
            "\"extra\":{\"future\":true}}",
        .{},
    );
    defer running.deinit();
    const running_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        running.value,
    );
    try std.testing.expect(running_snapshot.running);
    try std.testing.expectEqual(
        TerminalLifecycle.running,
        running_snapshot.lifecycle,
    );
    try std.testing.expect(running_snapshot.exit == null);

    var legacy_attached = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_id\":\"tab_77777777777777777777777777777777\"," ++
            "\"title\":\"legacy\",\"cols\":80,\"rows\":24," ++
            "\"running\":true,\"lifecycle\":\"running\"}",
        .{},
    );
    defer legacy_attached.deinit();
    const legacy_attached_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        legacy_attached.value,
    );
    try std.testing.expectEqual(@as(usize, 1), legacy_attached_snapshot.tab_ids.len);

    var legacy_detached = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\",\"tab_id\":null," ++
            "\"title\":\"legacy\",\"cols\":80,\"rows\":24," ++
            "\"running\":true,\"lifecycle\":\"running\"}",
        .{},
    );
    defer legacy_detached.deinit();
    const legacy_detached_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        legacy_detached.value,
    );
    try std.testing.expectEqual(@as(usize, 0), legacy_detached_snapshot.tab_ids.len);

    var consistent_alias = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_id\":\"tab_77777777777777777777777777777777\"," ++
            "\"tab_ids\":[\"tab_77777777777777777777777777777777\"]," ++
            "\"title\":\"legacy\",\"cols\":80,\"rows\":24," ++
            "\"running\":true,\"lifecycle\":\"running\"}",
        .{},
    );
    defer consistent_alias.deinit();
    const consistent_alias_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        consistent_alias.value,
    );
    try std.testing.expectEqual(@as(usize, 1), consistent_alias_snapshot.tab_ids.len);

    var inconsistent_alias = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_id\":\"tab_77777777777777777777777777777777\",\"tab_ids\":[]," ++
            "\"title\":\"legacy\",\"cols\":80,\"rows\":24," ++
            "\"running\":true,\"lifecycle\":\"running\"}",
        .{},
    );
    defer inconsistent_alias.deinit();
    try std.testing.expectError(
        error.InvalidTerminalPlacement,
        decodeTerminalSnapshot(
            decoded_arena.allocator(),
            inconsistent_alias.value,
        ),
    );

    var exited = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_ids\":[]," ++
            "\"title\":\"done\",\"cols\":80,\"rows\":24," ++
            "\"running\":false,\"lifecycle\":\"exited\",\"exit\":{" ++
            "\"outcome\":{\"kind\":\"exit\",\"code\":-7}," ++
            "\"exited_at\":\"18446744073709551615\"," ++
            "\"revision\":\"18446744073709551614\"}}",
        .{},
    );
    defer exited.deinit();
    const exited_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        exited.value,
    );
    try std.testing.expectEqual(@as(usize, 0), exited_snapshot.tab_ids.len);
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        exited_snapshot.exit.?.exited_at,
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        exited_snapshot.exit.?.revision,
    );
    switch (exited_snapshot.exit.?.outcome) {
        .exit => |code| try std.testing.expectEqual(
            @as(i32, -7),
            code,
        ),
        else => return error.ExpectedTerminalExitCode,
    }

    var future = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_ids\":[\"tab_77777777777777777777777777777777\"]," ++
            "\"title\":\"future\",\"cols\":80,\"rows\":24," ++
            "\"running\":false,\"lifecycle\":\"suspended\"}",
        .{},
    );
    defer future.deinit();
    const future_snapshot = try decodeTerminalSnapshot(
        decoded_arena.allocator(),
        future.value,
    );
    switch (future_snapshot.lifecycle) {
        .unknown => |value| try std.testing.expectEqualStrings(
            "suspended",
            value,
        ),
        else => return error.ExpectedUnknownTerminalLifecycle,
    }

    var inconsistent = try raw.wire.parse(
        std.testing.allocator,
        "{\"id\":\"term_0123456789abcdef0123456789abcdef\"," ++
            "\"tab_ids\":[\"tab_77777777777777777777777777777777\"]," ++
            "\"title\":\"bad\",\"cols\":80,\"rows\":24," ++
            "\"running\":false,\"lifecycle\":\"running\"}",
        .{},
    );
    defer inconsistent.deinit();
    try std.testing.expectError(
        error.InvalidTerminalState,
        decodeTerminalSnapshot(decoded_arena.allocator(), inconsistent.value),
    );
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
        try std.testing.expect(client.isClosed());
        try std.testing.expect(shared.closed);
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
            .code = "confirmation.required",
            .details = "{\"revision\":\"3\",\"closes_panes\":[" ++
                "\"pane_11111111111111111111111111111111\"]," ++
                "\"confirmation_token\":\"confirm-3\"}",
            .tag = .confirmation_required,
        },
        .{
            .code = "creation.conflict",
            .details = "{\"correlation_key\":\"create-1\"," ++
                "\"existing_operation\":\"workspace.create\"," ++
                "\"requested_operation\":\"terminal.create\"," ++
                "\"existing_fingerprint\":\"sha256:old\"," ++
                "\"requested_fingerprint\":\"sha256:new\"}",
            .tag = .creation_conflict,
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
    try std.testing.expectEqual(@as(usize, 16), fixtures.len);

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
        if (std.mem.eql(u8, fixture.code, "confirmation.required")) {
            const details = switch (owned.value.details) {
                .confirmation_required => |value| value,
                else => unreachable,
            };
            try std.testing.expectEqualStrings(
                "confirm-3",
                details.confirmation_token,
            );
            try std.testing.expectEqual(@as(u64, 3), details.revision);
        }
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
        "\"id\":\"" ++ workspace_id ++ "\"," ++
        "\"session_id\":\"session_0123456789abcdef0123456789abcdef\"," ++
        "\"name\":\"sdk\",\"index\":0,\"focused\":true}}," ++
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
        "\"reset_reason\":\"initial\",\"snapshot\":{" ++
        "\"machine\":{\"id\":\"machine_0123456789abcdef0123456789abcdef\"," ++
        "\"name\":\"local\",\"origin\":\"local\",\"status\":\"running\"," ++
        "\"connectable\":true," ++
        "\"deleted\":false,\"recoverable\":false}," ++
        "\"session\":{\"id\":\"session_0123456789abcdef0123456789abcdef\"," ++
        "\"machine_id\":\"machine_0123456789abcdef0123456789abcdef\"," ++
        "\"name\":\"main\",\"generation\":\"g\",\"revision\":\"3\"," ++
        "\"connected\":true}," ++
        "\"workspaces\":[],\"screens\":[],\"panes\":[],\"tabs\":[]," ++
        "\"terminals\":[],\"browsers\":[],\"clients\":[]," ++
        "\"notifications\":[],\"agents\":[],\"frontend_projections\":[]," ++
        "\"sidebar_views\":[],\"cursor\":{\"generation\":\"g\"," ++
        "\"revision\":\"3\"}}}";
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

test "typed attachment decoders preserve unknown discriminators" {
    var decoded = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded.deinit();

    var terminal = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"future.terminal\",\"future\":true}",
        .{},
    );
    defer terminal.deinit();
    switch (try decodeTerminalAttachmentItem(
        decoded.allocator(),
        terminal.value,
    )) {
        .unknown => |unknown| {
            try std.testing.expectEqualStrings(
                "future.terminal",
                unknown.discriminator,
            );
            try std.testing.expect(
                unknown.raw_object.object.get("future").?.bool,
            );
        },
        else => return error.ExpectedUnknownTerminalAttachment,
    }

    var browser = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"future.browser\",\"future\":true}",
        .{},
    );
    defer browser.deinit();
    switch (try decodeBrowserAttachmentItem(
        decoded.allocator(),
        browser.value,
    )) {
        .unknown => |unknown| try std.testing.expectEqualStrings(
            "future.browser",
            unknown.discriminator,
        ),
        else => return error.ExpectedUnknownBrowserAttachment,
    }

    var sidebar = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"future.sidebar\",\"future\":true}",
        .{},
    );
    defer sidebar.deinit();
    switch (try decodeSidebarViewItem(
        decoded.allocator(),
        sidebar.value,
    )) {
        .unknown => |unknown| try std.testing.expectEqualStrings(
            "future.sidebar",
            unknown.discriminator,
        ),
        else => return error.ExpectedUnknownSidebarAttachment,
    }

    var malformed = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"scroll\"}",
        .{},
    );
    defer malformed.deinit();
    try std.testing.expectError(
        error.MissingField,
        decodeTerminalAttachmentItem(
            decoded.allocator(),
            malformed.value,
        ),
    );
}

test "browser frames require a nullable canonical pointer token" {
    var decoded = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decoded.deinit();

    var maximum = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"frame\",\"mime_type\":\"image/png\"," ++
            "\"data_base64\":\"AA==\",\"width_px\":1," ++
            "\"height_px\":1,\"pointer_frame_seq\":" ++
            "\"18446744073709551615\"}",
        .{},
    );
    defer maximum.deinit();
    switch (try decodeBrowserAttachmentItem(
        decoded.allocator(),
        maximum.value,
    )) {
        .frame => |frame| {
            try std.testing.expectEqual(
                @as(?u64, std.math.maxInt(u64)),
                frame.pointer_frame_seq,
            );
            try std.testing.expectEqualSlices(
                u8,
                &.{0},
                frame.data,
            );
        },
        else => return error.ExpectedBrowserFrame,
    }

    var unavailable = try raw.wire.parse(
        std.testing.allocator,
        "{\"kind\":\"frame\",\"mime_type\":\"image/png\"," ++
            "\"data_base64\":\"AA==\",\"width_px\":1," ++
            "\"height_px\":1,\"pointer_frame_seq\":null}",
        .{},
    );
    defer unavailable.deinit();
    switch (try decodeBrowserAttachmentItem(
        decoded.allocator(),
        unavailable.value,
    )) {
        .frame => |frame| try std.testing.expect(
            frame.pointer_frame_seq == null,
        ),
        else => return error.ExpectedBrowserFrame,
    }

    const invalid_cases = [_]struct {
        json: []const u8,
        expected: anyerror,
    }{
        .{
            .json = "{\"kind\":\"frame\",\"mime_type\":\"image/png\"," ++
                "\"data_base64\":\"AA==\",\"width_px\":1," ++
                "\"height_px\":1}",
            .expected = error.MissingField,
        },
        .{
            .json = "{\"kind\":\"frame\",\"mime_type\":\"image/png\"," ++
                "\"data_base64\":\"AA==\",\"width_px\":1," ++
                "\"height_px\":1,\"pointer_frame_seq\":7}",
            .expected = error.ExpectedDecimalString,
        },
        .{
            .json = "{\"kind\":\"frame\",\"mime_type\":\"image/png\"," ++
                "\"data_base64\":\"AA==\",\"width_px\":1," ++
                "\"height_px\":1,\"pointer_frame_seq\":\"07\"}",
            .expected = error.InvalidDecimalString,
        },
        .{
            .json = "{\"kind\":\"frame\",\"mime_type\":\"image/gif\"," ++
                "\"data_base64\":\"AA==\",\"width_px\":1," ++
                "\"height_px\":1,\"pointer_frame_seq\":null}",
            .expected = error.InvalidBrowserFrameMime,
        },
    };
    for (invalid_cases) |case| {
        var parsed = try raw.wire.parse(
            std.testing.allocator,
            case.json,
            .{},
        );
        defer parsed.deinit();
        try std.testing.expectError(
            case.expected,
            decodeBrowserAttachmentItem(
                decoded.allocator(),
                parsed.value,
            ),
        );
    }
}

test "resource client closes after either framing write fails" {
    for ([_]usize{ 1, 2 }) |fail_write_call| {
        var shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .fail_write_call = fail_write_call,
        };
        defer shared.deinit();
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
        var params = raw.wire.Object.init(std.testing.allocator);
        defer params.deinit();

        try std.testing.expectError(
            error.InjectedWriteFailure,
            client.sendRequest(
                "zig-write-failure",
                .machine_list,
                .{ .object = params },
                null,
            ),
        );
        try std.testing.expect(client.isClosed());
        try std.testing.expect(shared.closed);
        const bytes_after_failure = shared.output.items.len;
        try std.testing.expectError(
            error.ConnectionClosed,
            client.sendRequest(
                "zig-after-write-failure",
                .machine_list,
                .{ .object = params },
                null,
            ),
        );
        try std.testing.expectEqual(
            bytes_after_failure,
            shared.output.items.len,
        );
    }
}

test "stream open requires an exact result and valid optional cursor" {
    const cases = [_]struct {
        ack: FakeStreamOpenAck,
        expected: anyerror,
    }{
        .{
            .ack = .missing_result,
            .expected = error.MissingResponseResult,
        },
        .{
            .ack = .missing_stream_id,
            .expected = error.MissingField,
        },
        .{
            .ack = .mismatched_stream_id,
            .expected = error.StreamIdMismatch,
        },
        .{
            .ack = .non_object,
            .expected = error.ExpectedObject,
        },
        .{
            .ack = .unknown_field,
            .expected = error.UnexpectedField,
        },
        .{
            .ack = .null_cursor,
            .expected = error.ExpectedObject,
        },
        .{
            .ack = .malformed_cursor,
            .expected = error.ExpectedDecimalString,
        },
        .{
            .ack = .cursor_unknown_field,
            .expected = error.UnexpectedField,
        },
        .{
            .ack = .empty_cursor_generation,
            .expected = error.InvalidCursorGeneration,
        },
        .{
            .ack = .oversized_cursor_generation,
            .expected = error.InvalidCursorGeneration,
        },
    };
    for (cases) |case| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .stream_open_ack = case.ack,
        };
        defer stream_shared.deinit();
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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

        try std.testing.expectError(
            case.expected,
            client.session(session_id).events(),
        );
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "stream connection setup consumes the open deadline" {
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
    var factory_state = StreamFactoryState{
        .shared = &stream_shared,
        .open_delay_ms = 25,
    };
    const connection = try fakeConnection(
        std.testing.allocator,
        &control_shared,
    );
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 10,
        .stream_factory = .{
            .context = &factory_state,
            .openFn = StreamFactoryState.open,
        },
    });
    defer client.deinit();
    const session_id = try SessionId.parse(
        "session_0123456789abcdef0123456789abcdef",
    );

    const failure = blk: {
        var stream = client.session(session_id).events() catch |err| {
            break :blk err;
        };
        stream.deinit();
        return error.ExpectedTimeout;
    };
    try std.testing.expectEqual(error.Timeout, failure);
    try std.testing.expectEqual(@as(usize, 1), factory_state.open_calls);
    try std.testing.expect(
        factory_state.open_timeout_ms != null and
            factory_state.open_timeout_ms.? <= 10,
    );
    try std.testing.expectEqual(@as(usize, 0), stream_shared.write_calls);
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
}

test "stream open accepts a valid optional cursor" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
        .stream_open_ack = .matching_with_cursor,
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
    try std.testing.expect(!stream_shared.closed);
}

test "stream open buffers pre-ack items in wire order" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
        .stream_open_preamble = .item_before_ack,
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
    try std.testing.expectEqual(
        @as(usize, 1),
        stream.raw_stream.pending.items.len,
    );
    var first = (try stream.next()) orelse
        return error.MissingPreAckStreamItem;
    defer first.deinit();
    var second = (try stream.next()) orelse
        return error.MissingPostAckStreamItem;
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expectEqual(@as(u64, 2), second.sequence);
    try std.testing.expect(!stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
}

test "stream open drains pre-ack items before a pre-ack end" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
        .stream_open_preamble = .item_then_end_before_ack,
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
    var first = (try stream.next()) orelse
        return error.MissingPreAckStreamItem;
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.sequence);
    try std.testing.expect((try stream.next()) == null);
    const end = stream.end() orelse return error.MissingStreamEnd;
    try std.testing.expectEqual(StreamEndReason.completed, end.reason);
    try std.testing.expectEqual(@as(u64, 1), end.cursor.?.revision);
    try std.testing.expect(!stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
}

test "stream open rejects invalid and overflowing pre-ack envelopes" {
    const cases = [_]struct {
        preamble: FakeStreamOpenPreamble,
        expected: anyerror,
    }{
        .{
            .preamble = .count_overflow,
            .expected = error.StreamBufferFull,
        },
        .{
            .preamble = .malformed_item,
            .expected = error.ExpectedDecimalString,
        },
        .{
            .preamble = .wrong_item,
            .expected = error.StreamIdMismatch,
        },
        .{
            .preamble = .wrong_end,
            .expected = error.StreamIdMismatch,
        },
        .{
            .preamble = .item_after_end,
            .expected = error.UnexpectedStreamEnvelope,
        },
    };
    for (cases) |case| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .stream_open_preamble = case.preamble,
        };
        defer stream_shared.deinit();
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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

        try std.testing.expectError(
            case.expected,
            client.session(session_id).events(),
        );
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "stream items require exact canonical envelopes and known payloads" {
    const Case = enum {
        unknown_field,
        invalid_protocol,
        wrong_type,
        wrong_stream_id,
        numeric_sequence,
        non_canonical_sequence,
        null_cursor,
        cursor_unknown_field,
        malformed_known_item,
    };
    const cases = [_]struct {
        case: Case,
        expected: anyerror,
    }{
        .{ .case = .unknown_field, .expected = error.UnexpectedField },
        .{
            .case = .invalid_protocol,
            .expected = error.InvalidProtocolEnvelope,
        },
        .{ .case = .wrong_type, .expected = error.UnexpectedStreamEnvelope },
        .{ .case = .wrong_stream_id, .expected = error.StreamIdMismatch },
        .{
            .case = .numeric_sequence,
            .expected = error.ExpectedDecimalString,
        },
        .{
            .case = .non_canonical_sequence,
            .expected = error.InvalidDecimalString,
        },
        .{ .case = .null_cursor, .expected = error.ExpectedObject },
        .{
            .case = .cursor_unknown_field,
            .expected = error.UnexpectedField,
        },
        .{
            .case = .malformed_known_item,
            .expected = error.UnexpectedField,
        },
    };
    for (cases) |case| {
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
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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
        var initial = (try stream.next()) orelse
            return error.MissingInitialStreamItem;
        initial.deinit();
        const stream_id = stream.raw_stream.stream_id.slice();
        const encoded = switch (case.case) {
            .unknown_field => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"item\":{{\"kind\":" ++
                    "\"future.event\"}},\"future\":true}}",
                .{stream_id},
            ),
            .invalid_protocol => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/999\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"item\":{{\"kind\":" ++
                    "\"future.event\"}}}}",
                .{stream_id},
            ),
            .wrong_type => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"future_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"item\":{{\"kind\":" ++
                    "\"future.event\"}}}}",
                .{stream_id},
            ),
            .wrong_stream_id => try std.testing.allocator.dupe(
                u8,
                "{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":" ++
                    "\"stream_ffffffffffffffffffffffffffffffff\"," ++
                    "\"sequence\":\"2\",\"item\":{\"kind\":" ++
                    "\"future.event\"}}",
            ),
            .numeric_sequence => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":2,\"item\":{{\"kind\":" ++
                    "\"future.event\"}}}}",
                .{stream_id},
            ),
            .non_canonical_sequence => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"02\",\"item\":{{\"kind\":" ++
                    "\"future.event\"}}}}",
                .{stream_id},
            ),
            .null_cursor => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"cursor\":null," ++
                    "\"item\":{{\"kind\":\"future.event\"}}}}",
                .{stream_id},
            ),
            .cursor_unknown_field => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"cursor\":{{" ++
                    "\"generation\":\"g\",\"revision\":\"2\"," ++
                    "\"future\":true}},\"item\":{{\"kind\":" ++
                    "\"future.event\"}}}}",
                .{stream_id},
            ),
            .malformed_known_item => try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                    "\"stream_item\",\"stream_id\":\"{s}\"," ++
                    "\"sequence\":\"2\",\"item\":{{\"kind\":" ++
                    "\"snapshot\",\"future\":true}}}}",
                .{stream_id},
            ),
        };
        defer std.testing.allocator.free(encoded);
        try stream_shared.appendInput(encoded);

        try std.testing.expectError(case.expected, stream.next());
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
    }
}

test "stream read transport failure closes its dedicated client" {
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
    var initial = (try stream.next()) orelse
        return error.MissingInitialStreamItem;
    initial.deinit();
    stream_shared.read_failure = error.InjectedTransportFailure;

    try std.testing.expectError(
        error.InjectedTransportFailure,
        stream.next(),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    stream_shared.read_failure = null;
    try std.testing.expectError(error.ConnectionClosed, stream.next());
}

test "stream control transport failure closes its dedicated client" {
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
    var initial = (try stream.next()) orelse
        return error.MissingInitialStreamItem;
    initial.deinit();
    stream_shared.read_failure = error.InjectedTransportFailure;
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.InjectedTransportFailure,
        stream.raw_stream.control(
            .terminal_viewer_release,
            .{ .object = params },
        ),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    const writes_after_failure = stream_shared.write_calls;
    stream_shared.read_failure = null;
    try std.testing.expectError(
        error.ConnectionClosed,
        stream.raw_stream.control(
            .terminal_viewer_release,
            .{ .object = params },
        ),
    );
    try std.testing.expectEqual(
        writes_after_failure,
        stream_shared.write_calls,
    );
}

test "valid stream control rejection preserves its dedicated client" {
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
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();
    stream_shared.mode = .remote_error;

    try std.testing.expectError(
        error.RemoteError,
        stream.raw_stream.control(
            .terminal_viewer_release,
            .{ .object = params },
        ),
    );
    try std.testing.expect(!stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    stream_shared.mode = .typed_catalog;
    var result = try stream.raw_stream.control(
        .terminal_viewer_release,
        .{ .object = params },
    );
    result.deinit();
    try std.testing.expect(!stream_shared.closed);
}

test "known stream ends require exact canonical envelopes" {
    const cases = [_]struct {
        fields: []const u8,
        expected: anyerror,
    }{
        .{
            .fields = "\"reason\":\"completed\",\"future\":true",
            .expected = error.UnexpectedField,
        },
        .{
            .fields = "\"reason\":\"completed\",\"cursor\":null",
            .expected = error.ExpectedObject,
        },
        .{
            .fields = "\"reason\":\"completed\",\"recovery\":null",
            .expected = error.ExpectedString,
        },
        .{
            .fields = "\"reason\":\"completed\",\"error\":{" ++
                "\"code\":\"failed\",\"message\":\"bad\"," ++
                "\"details\":{},\"retryable\":false}",
            .expected = error.InvalidStreamEndErrorPresence,
        },
        .{
            .fields = "\"reason\":\"error\"",
            .expected = error.InvalidStreamEndErrorPresence,
        },
        .{
            .fields = "\"reason\":\"error\",\"error\":{" ++
                "\"code\":\"failed\",\"message\":\"bad\"," ++
                "\"details\":{},\"retryable\":false," ++
                "\"future\":true}",
            .expected = error.UnexpectedField,
        },
        .{
            .fields = "\"reason\":\"error\",\"error\":{" ++
                "\"code\":\"failed\",\"message\":\"bad\"," ++
                "\"details\":{},\"retryable\":\"no\"}",
            .expected = error.ExpectedBool,
        },
    };
    for (cases) |case| {
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
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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
        var initial = (try stream.next()) orelse
            return error.MissingInitialStreamItem;
        initial.deinit();
        const encoded = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
                "\"stream_end\",\"stream_id\":\"{s}\",{s}}}",
            .{ stream.raw_stream.stream_id.slice(), case.fields },
        );
        defer std.testing.allocator.free(encoded);
        try stream_shared.appendInput(encoded);

        try std.testing.expectError(case.expected, stream.next());
    }
}

test "known stream end accepts an exact embedded error" {
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
    var initial = (try stream.next()) orelse
        return error.MissingInitialStreamItem;
    initial.deinit();
    const encoded = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
            "\"stream_end\",\"stream_id\":\"{s}\"," ++
            "\"reason\":\"error\",\"cursor\":{{\"generation\":" ++
            "\"g\",\"revision\":\"4\"}},\"recovery\":" ++
            "\"open a fresh stream\",\"error\":{{\"code\":" ++
            "\"stream.failed\",\"message\":\"bad\"," ++
            "\"details\":{{}},\"retryable\":true}}}}",
        .{stream.raw_stream.stream_id.slice()},
    );
    defer std.testing.allocator.free(encoded);
    try stream_shared.appendInput(encoded);

    try std.testing.expect((try stream.next()) == null);
    const end = stream.end() orelse return error.MissingStreamEnd;
    try std.testing.expectEqual(StreamEndReason.@"error", end.reason);
    try std.testing.expectEqualStrings(
        "stream.failed",
        end.resource_error.?.code,
    );
    try std.testing.expectEqualStrings(
        "open a fresh stream",
        end.recovery.?,
    );
}

test "valid stream open rejection closes without cancellation" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .remote_error,
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

    try std.testing.expectError(
        error.RemoteError,
        client.session(session_id).events(),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
}

test "acknowledged public stream survives beyond request timeout" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .delayed_stream_item,
    };
    defer stream_shared.deinit();
    var factory_state = StreamFactoryState{ .shared = &stream_shared };
    const connection = try fakeConnection(
        std.testing.allocator,
        &control_shared,
    );
    const request_timeout_ms: u32 = 2;
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = request_timeout_ms,
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

    const started_at = std.time.nanoTimestamp();
    var item = (try stream.next()) orelse
        return error.MissingDelayedStreamItem;
    defer item.deinit();
    const elapsed_ns = std.time.nanoTimestamp() - started_at;

    try std.testing.expect(
        stream_shared.delayed_stream_open_read_observed,
    );
    const open_timeout_ms = stream_shared.delayed_stream_open_timeout_ms orelse
        return error.MissingDelayedStreamOpenTimeout;
    try std.testing.expect(open_timeout_ms > 0);
    try std.testing.expect(open_timeout_ms <= request_timeout_ms);
    try std.testing.expect(stream_shared.delayed_stream_read_started);
    try std.testing.expect(
        !stream_shared.delayed_stream_read_had_deadline,
    );
    try std.testing.expect(
        elapsed_ns >= fake_delayed_stream_wait_ms * std.time.ns_per_ms,
    );
    try std.testing.expect(
        fake_delayed_stream_wait_ms > request_timeout_ms,
    );
    try std.testing.expectEqual(@as(u64, 1), item.sequence);
    switch (item.value) {
        .unknown => |unknown| try std.testing.expectEqualStrings(
            "future.event",
            unknown.discriminator,
        ),
        else => return error.ExpectedUnknownSessionEvent,
    }
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
    const repeated_end = try stream.cancel();
    try std.testing.expectEqual(
        StreamEndReason.canceled,
        repeated_end.reason,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
    try std.testing.expect(stream_shared.closed);
}

test "session journal encodes filters and decodes typed records" {
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
    var stream = try client.session(session_id).journal(.{
        .start = .beginning,
        .follow = false,
        .filter = .{
            .kinds = &.{ "workspace.*", "tab.focus" },
            .classes = &.{.state},
            .subjects = &.{.{ .kind = "workspace", .id = "ws_1" }},
            .max_sensitivity = .metadata,
            .regex = .{
                .pattern = "error|failed",
                .field = .terminal_output,
                .case_sensitive = false,
            },
        },
    });
    defer stream.deinit();
    var item = (try stream.next()).?;
    defer item.deinit();
    try std.testing.expectEqual(@as(u64, 1), item.value.sequence);
    try std.testing.expectEqualStrings(
        "workspace.focus",
        item.value.kind,
    );
    try std.testing.expectEqual(
        JournalClass.state,
        item.value.journal_class,
    );
    try std.testing.expectEqual(@as(usize, 1), item.value.subjects.len);
    try std.testing.expectEqualStrings(
        "ws_1",
        item.value.subjects[0].id,
    );

    const request_line = std.mem.sliceTo(stream_shared.output.items, '\n');
    var request = try raw.wire.parse(
        std.testing.allocator,
        request_line,
        .{},
    );
    defer request.deinit();
    const request_object = try detailObject(request.value);
    try std.testing.expectEqualStrings(
        "session.journal.subscribe",
        try objectString(request_object, "operation"),
    );
    const params = try detailObject(
        request_object.get("params") orelse return error.MissingField,
    );
    try std.testing.expectEqualStrings(
        "beginning",
        try objectString(params, "start"),
    );
    try std.testing.expectEqual(false, try objectBool(params, "follow"));
    const filter = try detailObject(
        params.get("filter") orelse return error.MissingField,
    );
    try std.testing.expectEqualStrings(
        "metadata",
        try objectString(filter, "max_sensitivity"),
    );
    const regex = try detailObject(
        filter.get("regex") orelse return error.MissingField,
    );
    try std.testing.expectEqualStrings(
        "terminal_output",
        try objectString(regex, "field"),
    );
    try std.testing.expectEqual(false, try objectBool(regex, "case_sensitive"));
}

test "cancel failures preserve their error fail closed and never resend" {
    const cases = [_]struct {
        response: FakeCancelResponse,
        expected: anyerror,
    }{
        .{
            .response = .non_empty,
            .expected = error.UnexpectedField,
        },
        .{
            .response = .invalid_protocol,
            .expected = error.InvalidProtocolEnvelope,
        },
        .{
            .response = .rejected,
            .expected = error.RemoteError,
        },
        .{
            .response = .extra_field,
            .expected = error.UnexpectedField,
        },
        .{
            .response = .success_with_error,
            .expected = error.UnexpectedField,
        },
        .{
            .response = .failure_with_result,
            .expected = error.UnexpectedField,
        },
        .{
            .response = .malformed_error,
            .expected = error.UnexpectedField,
        },
    };
    for (cases) |case| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .cancel_response = case.response,
        };
        defer stream_shared.deinit();
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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

        try std.testing.expectError(case.expected, stream.cancel());
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
        if (case.response == .rejected) {
            try std.testing.expectEqualStrings(
                "stream.cancel_rejected",
                stream.raw_stream.client.lastResourceError().?.code,
            );
        }
        try std.testing.expectError(
            case.expected,
            stream.cancel(),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "cancel rejects malformed terminal ends fail closed and never resend" {
    const cases = [_]struct {
        end: FakeCancelEnd,
        expected: anyerror,
    }{
        .{
            .end = .invalid_protocol,
            .expected = error.InvalidProtocolEnvelope,
        },
        .{
            .end = .missing_reason,
            .expected = error.MissingField,
        },
        .{
            .end = .wrong_stream_id,
            .expected = error.StreamIdMismatch,
        },
        .{
            .end = .wrong_reason,
            .expected = error.UnexpectedStreamEndReason,
        },
        .{
            .end = .unknown_field,
            .expected = error.UnexpectedField,
        },
        .{
            .end = .null_cursor,
            .expected = error.ExpectedObject,
        },
        .{
            .end = .malformed_cursor,
            .expected = error.ExpectedDecimalString,
        },
        .{
            .end = .null_recovery,
            .expected = error.ExpectedString,
        },
        .{
            .end = .unexpected_error,
            .expected = error.InvalidStreamEndErrorPresence,
        },
    };
    for (cases) |case| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .cancel_end = case.end,
        };
        defer stream_shared.deinit();
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
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

        try std.testing.expectError(case.expected, stream.cancel());
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
        try std.testing.expectError(
            case.expected,
            stream.cancel(),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "cancel missing terminal end expires once and fails closed" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
        .cancel_end = .missing,
    };
    defer stream_shared.deinit();
    var factory_state = StreamFactoryState{ .shared = &stream_shared };
    const connection = try fakeConnection(
        std.testing.allocator,
        &control_shared,
    );
    var client = Client.init(std.testing.allocator, connection, .{
        .timeout_ms = 20,
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

    try std.testing.expectError(error.Timeout, stream.cancel());
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expect(stream_shared.cancel_read_calls >= 2);
    try std.testing.expectError(error.Timeout, stream.cancel());
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
}

test "cancel has one total deadline across stale and fragmented reads" {
    for ([_]FakeCancelDelivery{ .stale_items, .fragmented }) |delivery| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .cancel_delivery = delivery,
            .cancel_read_delay_ms = 12,
        };
        defer stream_shared.deinit();
        var factory_state = StreamFactoryState{
            .shared = &stream_shared,
        };
        const connection = try fakeConnection(
            std.testing.allocator,
            &control_shared,
        );
        var client = Client.init(std.testing.allocator, connection, .{
            .timeout_ms = 40,
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

        try std.testing.expectError(error.Timeout, stream.cancel());
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expect(stream_shared.cancel_read_calls >= 2);
        const first_timeout = stream_shared.cancel_first_read_timeout_ms orelse
            return error.MissingFirstCancelReadTimeout;
        const last_timeout = stream_shared.cancel_last_read_timeout_ms orelse
            return error.MissingLastCancelReadTimeout;
        try std.testing.expect(first_timeout > last_timeout);
        try std.testing.expect(
            stream_shared.read_cursor < stream_shared.input.items.len,
        );
        try std.testing.expectError(
            error.Timeout,
            stream.cancel(),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "cancel rejects valid and malformed known items after end before response" {
    for ([_]FakeCancelDelivery{
        .valid_known_item_after_end,
        .malformed_known_item,
    }) |delivery| {
        var control_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
        };
        defer control_shared.deinit();
        var stream_shared = FakeShared{
            .allocator = std.testing.allocator,
            .mode = .success,
            .cancel_delivery = delivery,
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

        try std.testing.expectError(
            error.UnexpectedStreamEnvelope,
            stream.cancel(),
        );
        const received_end = stream.end() orelse
            return error.MissingCanceledEndBeforePostEndItem;
        try std.testing.expectEqual(
            StreamEndReason.canceled,
            received_end.reason,
        );
        try std.testing.expect(stream.raw_stream.cleanup_started);
        try std.testing.expect(!stream.raw_stream.cleanup_finished);
        try std.testing.expect(stream_shared.closed);
        try std.testing.expect(!control_shared.closed);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
        try std.testing.expectError(
            error.UnexpectedStreamEnvelope,
            stream.cancel(),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                stream_shared.output.items,
                "\"operation\":\"stream.cancel\"",
            ),
        );
    }
}

test "cancel preserves unknown stale typed items" {
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

    const end = try stream.cancel();
    try std.testing.expectEqual(StreamEndReason.canceled, end.reason);
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
}

test "cancel framing failure closes once and preserves the send error" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var stream_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
        .fail_write_call = 4,
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

    try std.testing.expectError(
        error.InjectedWriteFailure,
        stream.cancel(),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
    const bytes_after_failure = stream_shared.output.items.len;
    try std.testing.expectError(
        error.InjectedWriteFailure,
        stream.cancel(),
    );
    try std.testing.expectEqual(
        bytes_after_failure,
        stream_shared.output.items.len,
    );
}

test "auxiliary resource facades are typed and fully routed" {
    var shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer shared.deinit();
    const connection = try fakeConnection(std.testing.allocator, &shared);
    var client = Client.init(std.testing.allocator, connection, .{});
    defer client.deinit();
    const session_id = try SessionId.parse(
        "session_22222222222222222222222222222222",
    );
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    const session = client.session(session_id);

    var notification = try session.createNotification(.{
        .title = "Build complete",
        .body = "All tests passed",
        .terminal_id = terminal_id,
    }, try MutationOptions.withKey("notification-create"));
    defer notification.deinit();
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        notification.value.created_at_ms,
    );
    try std.testing.expect(notification.value.unread);

    var agent = try session.reportAgent(.{
        .terminal_id = terminal_id,
        .state = .working,
        .source = .hook,
    }, try MutationOptions.withKey("agent-report"));
    defer agent.deinit();
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        agent.value.updated_at_ms,
    );

    const pairing_id = try PairingRequestId.parse(
        "pairing_cccccccccccccccccccccccccccccccc",
    );
    var pairing = try session
        .pairingRequest(pairing_id)
        .resolvePairing(
        .accept,
        try MutationOptions.withKey("pairing-resolve"),
    );
    defer pairing.deinit();
    try std.testing.expectEqual(
        PairingStatus.accepted,
        pairing.value.pairing_request.status,
    );

    const projection_id = try FrontendProjectionId.parse(
        "projection_dddddddddddddddddddddddddddddddd",
    );
    var projection_arena = std.heap.ArenaAllocator.init(
        std.testing.allocator,
    );
    defer projection_arena.deinit();
    var projection_object = raw.wire.Object.init(
        projection_arena.allocator(),
    );
    try projection_object.put(
        "sidebar",
        .{ .string = "compact" },
    );
    var projection = try session
        .frontendProjection(projection_id)
        .putProjection(
        .{
            .frontend_id = "swift-frontend",
            .window_id = "window-1",
            .generation = "window-generation-1",
            .projection = .{ .object = projection_object },
        },
        try MutationOptions.withKey("projection-put"),
    );
    defer projection.deinit();
    try std.testing.expectEqualStrings(
        "compact",
        projection.value.projection.object.get("sidebar").?.string,
    );

    var ensured = try session.ensureSidebarView(.{
        .cols = 40,
        .rows = 30,
        .relaunch = true,
    }, try MutationOptions.withKey("sidebar-ensure"));
    defer ensured.deinit();
    const sidebar = session.sidebarView(ensured.value.id);
    var input = try sidebar.sendSidebarInput(
        "q\n",
        try MutationOptions.withKey("sidebar-input"),
    );
    defer input.deinit();
    var resized = try sidebar.resizeSidebar(
        40,
        30,
        try MutationOptions.withKey("sidebar-resize"),
    );
    defer resized.deinit();
    var reloaded = try sidebar.reloadSidebar(
        try MutationOptions.withKey("sidebar-reload"),
    );
    defer reloaded.deinit();
    try std.testing.expect(reloaded.value.running);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            shared.output.items,
            "\"data_base64\":\"cQo=\"",
        ) != null,
    );
    inline for (.{
        "notification.create",
        "agent.report",
        "pairing_request.resolve",
        "frontend_projection.put",
        "sidebar_view.ensure",
        "sidebar_view.input",
        "sidebar_view.resize",
        "sidebar_view.reload",
    }) |wire_name| {
        try std.testing.expect(
            std.mem.indexOf(u8, shared.output.items, wire_name) != null,
        );
    }
}

fn fakePendingStreamItem(
    allocator: std.mem.Allocator,
    stream_id: StreamId,
    sequence: usize,
    payload: []const u8,
) !raw.wire.OwnedValue {
    const encoded = try std.fmt.allocPrint(
        allocator,
        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
            "\"stream_item\",\"stream_id\":\"{s}\"," ++
            "\"sequence\":\"{d}\",\"cursor\":{{\"generation\":" ++
            "\"g\",\"revision\":\"{d}\"}},\"item\":{{\"kind\":" ++
            "\"future.event\",\"data\":\"{s}\"}}}}",
        .{ stream_id.slice(), sequence, sequence, payload },
    );
    defer allocator.free(encoded);
    return raw.wire.parse(allocator, encoded, .{});
}

test "stream count overflow is local and cancel observes the gap" {
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
    for (0..RawStream.max_buffered_items) |index| {
        const message = try fakePendingStreamItem(
            std.testing.allocator,
            stream.raw_stream.stream_id,
            index + 10,
            "",
        );
        try stream.raw_stream.queuePending(message);
    }
    const overflow_sequence = RawStream.max_buffered_items + 10;
    const overflow = try fakePendingStreamItem(
        std.testing.allocator,
        stream.raw_stream.stream_id,
        overflow_sequence,
        "",
    );
    try std.testing.expectError(
        error.StreamBufferFull,
        stream.raw_stream.queuePending(overflow),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expect(stream.raw_stream.cleanup_started);
    try std.testing.expect(stream.raw_stream.cleanup_finished);
    const end = stream.end().?;
    try std.testing.expectEqual(StreamEndReason.gap, end.reason);
    try std.testing.expectEqual(
        @as(u64, overflow_sequence),
        end.cursor.?.revision,
    );
    try std.testing.expectEqualStrings(
        "sdk.buffer_overflow",
        end.recovery.?,
    );
    const canceled = try stream.cancel();
    try std.testing.expectEqual(StreamEndReason.gap, canceled.reason);
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ) == null,
    );
}

test "overflow protocol failure closes once without later cancellation" {
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
    const malformed_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"protocol\":\"cmux.protocol/2\",\"type\":" ++
            "\"stream_item\",\"stream_id\":\"{s}\"," ++
            "\"sequence\":\"2\",\"cursor\":{{\"generation\":\"g\"," ++
            "\"revision\":2}},\"item\":{{}}}}",
        .{stream.raw_stream.stream_id.slice()},
    );
    defer std.testing.allocator.free(malformed_json);
    var malformed = try raw.wire.parse(
        std.testing.allocator,
        malformed_json,
        .{},
    );
    defer malformed.deinit();

    try std.testing.expectError(
        error.ExpectedDecimalString,
        stream.raw_stream.storeLocalOverflow(malformed.value),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expect(stream.raw_stream.cleanup_started);
    try std.testing.expect(!stream.raw_stream.cleanup_finished);
    try std.testing.expectError(
        error.ConnectionClosed,
        stream.cancel(),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(
            u8,
            stream_shared.output.items,
            "\"operation\":\"stream.cancel\"",
        ),
    );
}

test "stream byte overflow is bounded independently" {
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
    const payload = try std.testing.allocator.alloc(
        u8,
        1024 * 1024,
    );
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    var overflowed = false;
    for (0..32) |index| {
        const message = try fakePendingStreamItem(
            std.testing.allocator,
            stream.raw_stream.stream_id,
            index + 10,
            payload,
        );
        stream.raw_stream.queuePending(message) catch |failure| {
            if (failure != error.StreamBufferFull) return failure;
            overflowed = true;
            break;
        };
    }
    try std.testing.expect(overflowed);
    try std.testing.expect(
        stream.raw_stream.pending.items.len <
            RawStream.max_buffered_items,
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expectEqual(
        StreamEndReason.gap,
        stream.end().?.reason,
    );
}

test "stream control cumulative byte overflow owns rejected item once" {
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
    var initial = (try stream.next()) orelse
        return error.MissingInitialStreamItem;
    initial.deinit();

    const mebibyte = 1024 * 1024;
    const prefill_payload = try std.testing.allocator.alloc(u8, mebibyte);
    defer std.testing.allocator.free(prefill_payload);
    @memset(prefill_payload, 'p');
    var sequence: usize = 10;
    while (stream.raw_stream.pending_bytes <
        RawStream.max_buffered_bytes - 3 * mebibyte)
    {
        const message = try fakePendingStreamItem(
            std.testing.allocator,
            stream.raw_stream.stream_id,
            sequence,
            prefill_payload,
        );
        try stream.raw_stream.queuePending(message);
        sequence += 1;
    }

    const overflow_payload = try std.testing.allocator.alloc(
        u8,
        4 * mebibyte,
    );
    defer std.testing.allocator.free(overflow_payload);
    @memset(overflow_payload, 'x');
    var overflow = try fakePendingStreamItem(
        std.testing.allocator,
        stream.raw_stream.stream_id,
        sequence,
        overflow_payload,
    );
    defer overflow.deinit();
    const encoded = try raw.wire.stringifyAlloc(
        std.testing.allocator,
        overflow.value,
    );
    defer std.testing.allocator.free(encoded);
    try stream_shared.appendInput(encoded);
    var params = raw.wire.Object.init(std.testing.allocator);
    defer params.deinit();

    try std.testing.expectError(
        error.StreamBufferFull,
        stream.raw_stream.control(
            .terminal_viewer_release,
            .{ .object = params },
        ),
    );
    try std.testing.expect(stream_shared.closed);
    try std.testing.expect(!control_shared.closed);
    try std.testing.expectEqual(
        StreamEndReason.gap,
        stream.end().?.reason,
    );
}

test "attachment viewer controls use only dedicated connections" {
    var control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer control_shared.deinit();
    var terminal_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .typed_catalog,
    };
    defer terminal_shared.deinit();
    var terminal_factory = StreamFactoryState{
        .shared = &terminal_shared,
    };
    const connection = try fakeConnection(
        std.testing.allocator,
        &control_shared,
    );
    var client = Client.init(std.testing.allocator, connection, .{
        .stream_factory = .{
            .context = &terminal_factory,
            .openFn = StreamFactoryState.open,
        },
    });
    defer client.deinit();
    const terminal_id = try TerminalId.parse(
        "term_0123456789abcdef0123456789abcdef",
    );
    var terminal_stream = try client
        .terminal(terminal_id)
        .attachTerminalWith(.{
        .read_only = true,
        .cols = 80,
        .rows = 24,
    });
    defer terminal_stream.deinit();
    var terminal_resize = try terminal_stream.resizeTerminalViewer(
        100,
        30,
    );
    defer terminal_resize.deinit();
    try std.testing.expect(terminal_resize.value.accepted);
    var terminal_release =
        try terminal_stream.releaseTerminalViewer();
    defer terminal_release.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        control_shared.output.items.len,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            terminal_shared.output.items,
            "\"operation\":\"terminal.attach\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            terminal_shared.output.items,
            "\"read_only\":true",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            terminal_shared.output.items,
            "\"operation\":\"terminal.viewer.resize\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            terminal_shared.output.items,
            terminal_id.slice(),
        ) != null,
    );

    var browser_control_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .success,
    };
    defer browser_control_shared.deinit();
    var browser_shared = FakeShared{
        .allocator = std.testing.allocator,
        .mode = .typed_catalog,
    };
    defer browser_shared.deinit();
    var browser_factory = StreamFactoryState{
        .shared = &browser_shared,
    };
    const browser_connection = try fakeConnection(
        std.testing.allocator,
        &browser_control_shared,
    );
    var browser_client = Client.init(
        std.testing.allocator,
        browser_connection,
        .{
            .stream_factory = .{
                .context = &browser_factory,
                .openFn = StreamFactoryState.open,
            },
        },
    );
    defer browser_client.deinit();
    const browser_id = try BrowserId.parse(
        "browser_0123456789abcdef0123456789abcdef",
    );
    var browser_stream = try browser_client
        .browser(browser_id)
        .attachBrowserWith(.{
        .width_px = 1280,
        .height_px = 720,
    });
    defer browser_stream.deinit();
    var browser_resize = try browser_stream.resizeBrowserViewer(
        1440,
        900,
    );
    defer browser_resize.deinit();
    try std.testing.expect(browser_resize.value.accepted);
    var browser_release = try browser_stream.releaseBrowserViewer();
    defer browser_release.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        browser_control_shared.output.items.len,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            browser_shared.output.items,
            "\"operation\":\"browser.attach\"",
        ) != null,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            browser_shared.output.items,
            "\"operation\":\"browser.viewer.release\"",
        ) != null,
    );
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

test "renderer credentials redact formatting" {
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

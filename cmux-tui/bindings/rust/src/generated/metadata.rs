// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR b4e69e774777172ac0198454e7f068e53f7a74501dc787b58f3ead05d17b4af6.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use crate::{CommandMetadata, EventMetadata, ProfileMetadata, StreamMetadata};

pub const SDK_SCHEMA_VERSION: u32 = 2;
pub const MUX_PROTOCOL_VERSION: u32 = 12;
pub const SDK_IR_SHA256: &str = "b4e69e774777172ac0198454e7f068e53f7a74501dc787b58f3ead05d17b4af6";

#[rustfmt::skip]
pub const CONTROL_PROFILE: ProfileMetadata = ProfileMetadata {
    name: "control",
    description: "Base authenticated session-control commands available to ordinary SDK clients.",
    inherits: &[],
    transport: None,
    requires_authority: false,
};

#[rustfmt::skip]
pub const FRONTEND_PROFILE: ProfileMetadata = ProfileMetadata {
    name: "frontend",
    description: "Rendering, input, presentation, subscribe, and attach commands.",
    inherits: &["control"],
    transport: None,
    requires_authority: false,
};

#[rustfmt::skip]
pub const LOCAL_ADMIN_PROFILE: ProfileMetadata = ProfileMetadata {
    name: "local-admin",
    description: "Trusted local administration commands.",
    inherits: &["control"],
    transport: Some("Unix-classified transport, including direct Unix and the current stdio relay"),
    requires_authority: false,
};

#[rustfmt::skip]
pub const PROVIDER_AUTHORITY_PROFILE: ProfileMetadata = ProfileMetadata {
    name: "provider-authority",
    description: "Provider-owned workspace mutation commands.",
    inherits: &["control"],
    transport: None,
    requires_authority: true,
};

#[rustfmt::skip]
pub const APPLY_LAYOUT_METADATA: CommandMetadata = CommandMetadata {
    name: "apply-layout",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const ATTACH_SURFACE_METADATA: CommandMetadata = CommandMetadata {
    name: "attach-surface",
    since: 5,
    capability: None,
    authority: "frontend",
    stream: Some(StreamMetadata { kind: "attach", terminal_event: Some("detached") }),
};

#[rustfmt::skip]
pub const BROWSER_ACTIVATE_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-activate",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_BACK_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-back",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_FORWARD_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-forward",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_FRAME_PRESENTED_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-frame-presented",
    since: 10,
    capability: Some("browser-pointer-frame-guard-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_INSERT_TEXT_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-insert-text",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_KEY_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-key",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_KEY_PRESS_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-key-press",
    since: 10,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_MOUSE_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-mouse",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_MOUSE_GUARDED_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-mouse-guarded",
    since: 10,
    capability: Some("browser-pointer-frame-guard-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_NAVIGATE_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-navigate",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_RELOAD_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-reload",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_WHEEL_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-wheel",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const BROWSER_WHEEL_GUARDED_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-wheel-guarded",
    since: 10,
    capability: Some("browser-pointer-frame-guard-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const CLEAR_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "clear-history",
    since: 9,
    capability: Some("clear-history-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLEAR_WINDOW_TITLE_METADATA: CommandMetadata = CommandMetadata {
    name: "clear-window-title",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLIENT_FOCUS_METADATA: CommandMetadata = CommandMetadata {
    name: "client-focus",
    since: 12,
    capability: Some("client-focus-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "close-pane",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_PROVIDER_MANAGED_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "close-provider-managed-workspace",
    since: 9,
    capability: Some("provider-managed-workspace-authority-v2"),
    authority: "provider-authority",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "close-screen",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_SURFACE_METADATA: CommandMetadata = CommandMetadata {
    name: "close-surface",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "close-terminal",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "close-workspace",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const COPY_METADATA: CommandMetadata = CommandMetadata {
    name: "copy",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_SURFACE_WITH_RECEIPT_METADATA: CommandMetadata = CommandMetadata {
    name: "create-surface-with-receipt",
    since: 10,
    capability: Some("creation-receipts-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "create-terminal",
    since: 7,
    capability: Some("workspace-registry-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "create-workspace",
    since: 7,
    capability: Some("workspace-registry-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DETACH_ATTACHED_VIEW_METADATA: CommandMetadata = CommandMetadata {
    name: "detach-attached-view",
    since: 10,
    capability: Some("view-attachment-detach-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const DETACH_CLIENT_METADATA: CommandMetadata = CommandMetadata {
    name: "detach-client",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const EXPORT_LAYOUT_METADATA: CommandMetadata = CommandMetadata {
    name: "export-layout",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const FOCUS_DIRECTION_METADATA: CommandMetadata = CommandMetadata {
    name: "focus-direction",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const FOCUS_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "focus-pane",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const GET_BROWSER_PROVIDER_METADATA: CommandMetadata = CommandMetadata {
    name: "get-browser-provider",
    since: 10,
    capability: Some("browser-provider-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const GET_CELL_PIXELS_METADATA: CommandMetadata = CommandMetadata {
    name: "get-cell-pixels",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const GET_FRONTEND_PROJECTION_METADATA: CommandMetadata = CommandMetadata {
    name: "get-frontend-projection",
    since: 7,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const IDENTIFY_METADATA: CommandMetadata = CommandMetadata {
    name: "identify",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const IDS_METADATA: CommandMetadata = CommandMetadata {
    name: "ids",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const JOURNAL_FRONTEND_EVENT_METADATA: CommandMetadata = CommandMetadata {
    name: "journal-frontend-event",
    since: 10,
    capability: Some("frontend-journal-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_AGENTS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-agents",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_CLIENTS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-clients",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_TERMINALS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-terminals",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_WORKSPACES_METADATA: CommandMetadata = CommandMetadata {
    name: "list-workspaces",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MARK_WORKSPACES_PROVIDER_MANAGED_METADATA: CommandMetadata = CommandMetadata {
    name: "mark-workspaces-provider-managed",
    since: 9,
    capability: Some("provider-managed-workspace-authority-v2"),
    authority: "provider-authority",
    stream: None,
};

#[rustfmt::skip]
pub const MINT_TERMINAL_RENDERER_METADATA: CommandMetadata = CommandMetadata {
    name: "mint-terminal-renderer",
    since: 9,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const MINT_TERMINAL_RENDERER_BY_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "mint-terminal-renderer-by-terminal",
    since: 11,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "move-terminal",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-workspace",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_BROWSER_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "new-browser-tab",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "new-pane",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_PANE_RIGHT_METADATA: CommandMetadata = CommandMetadata {
    name: "new-pane-right",
    since: 9,
    capability: Some("viewport-splits-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "new-screen",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "new-tab",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "new-workspace",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NOTIFY_METADATA: CommandMetadata = CommandMetadata {
    name: "notify",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const PAIRING_RESPONSE_METADATA: CommandMetadata = CommandMetadata {
    name: "pairing-response",
    since: 7,
    capability: None,
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const PANE_NEIGHBOR_METADATA: CommandMetadata = CommandMetadata {
    name: "pane-neighbor",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const PING_METADATA: CommandMetadata = CommandMetadata {
    name: "ping",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const PROCESS_INFO_METADATA: CommandMetadata = CommandMetadata {
    name: "process-info",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const PUT_FRONTEND_PROJECTION_METADATA: CommandMetadata = CommandMetadata {
    name: "put-frontend-projection",
    since: 7,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const READ_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "read-screen",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const READ_SCROLLBACK_METADATA: CommandMetadata = CommandMetadata {
    name: "read-scrollback",
    since: 7,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const REGISTER_BROWSER_PROVIDER_METADATA: CommandMetadata = CommandMetadata {
    name: "register-browser-provider",
    since: 10,
    capability: Some("browser-provider-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const RELEASE_ATTACHED_VIEW_SIZE_METADATA: CommandMetadata = CommandMetadata {
    name: "release-attached-view-size",
    since: 10,
    capability: Some("view-attachment-lease-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const RELEASE_SURFACE_SIZE_METADATA: CommandMetadata = CommandMetadata {
    name: "release-surface-size",
    since: 7,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RELOAD_CONFIG_METADATA: CommandMetadata = CommandMetadata {
    name: "reload-config",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RENAME_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "rename-pane",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RENAME_PROVIDER_MANAGED_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "rename-provider-managed-workspace",
    since: 9,
    capability: Some("provider-managed-workspace-authority-v2"),
    authority: "provider-authority",
    stream: None,
};

#[rustfmt::skip]
pub const RENAME_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "rename-screen",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RENAME_SURFACE_METADATA: CommandMetadata = CommandMetadata {
    name: "rename-surface",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RENAME_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "rename-workspace",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const REPORT_AGENT_METADATA: CommandMetadata = CommandMetadata {
    name: "report-agent",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const REPORT_FOCUS_METADATA: CommandMetadata = CommandMetadata {
    name: "report-focus",
    since: 12,
    capability: Some("client-focus-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RESIZE_ATTACHED_VIEW_METADATA: CommandMetadata = CommandMetadata {
    name: "resize-attached-view",
    since: 10,
    capability: Some("view-attachment-lease-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const RESIZE_SURFACE_METADATA: CommandMetadata = CommandMetadata {
    name: "resize-surface",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RESOLVE_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "resolve-terminal",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const RUN_METADATA: CommandMetadata = CommandMetadata {
    name: "run",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SCROLL_SURFACE_METADATA: CommandMetadata = CommandMetadata {
    name: "scroll-surface",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SELECT_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "select-screen",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SELECT_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "select-tab",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SELECT_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "select-workspace",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SEND_METADATA: CommandMetadata = CommandMetadata {
    name: "send",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SEND_KEY_METADATA: CommandMetadata = CommandMetadata {
    name: "send-key",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_CELL_PIXELS_METADATA: CommandMetadata = CommandMetadata {
    name: "set-cell-pixels",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const SET_CLIENT_INFO_METADATA: CommandMetadata = CommandMetadata {
    name: "set-client-info",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_CLIENT_SIZING_METADATA: CommandMetadata = CommandMetadata {
    name: "set-client-sizing",
    since: 10,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_DEFAULT_COLORS_METADATA: CommandMetadata = CommandMetadata {
    name: "set-default-colors",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_RATIO_METADATA: CommandMetadata = CommandMetadata {
    name: "set-ratio",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_SPLIT_RATIO_METADATA: CommandMetadata = CommandMetadata {
    name: "set-split-ratio",
    since: 8,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_VIEWPORT_PANE_WIDTH_METADATA: CommandMetadata = CommandMetadata {
    name: "set-viewport-pane-width",
    since: 9,
    capability: Some("viewport-column-resize-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_WINDOW_TITLE_METADATA: CommandMetadata = CommandMetadata {
    name: "set-window-title",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SHUTDOWN_DAEMON_METADATA: CommandMetadata = CommandMetadata {
    name: "shutdown-daemon",
    since: 9,
    capability: None,
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const SIDEBAR_PLUGIN_METADATA: CommandMetadata = CommandMetadata {
    name: "sidebar-plugin",
    since: 6,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const SPLIT_METADATA: CommandMetadata = CommandMetadata {
    name: "split",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "subscribe",
    since: 5,
    capability: None,
    authority: "frontend",
    stream: Some(StreamMetadata { kind: "subscribe", terminal_event: None }),
};

#[rustfmt::skip]
pub const SWAP_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "swap-pane",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const TERMINAL_EVENTS_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-events",
    since: 9,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UNDO_LAYOUT_METADATA: CommandMetadata = CommandMetadata {
    name: "undo-layout",
    since: 9,
    capability: Some("layout-undo-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UNREGISTER_BROWSER_PROVIDER_METADATA: CommandMetadata = CommandMetadata {
    name: "unregister-browser-provider",
    since: 10,
    capability: Some("browser-provider-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const VT_STATE_METADATA: CommandMetadata = CommandMetadata {
    name: "vt-state",
    since: 5,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const WAIT_FOR_METADATA: CommandMetadata = CommandMetadata {
    name: "wait-for",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const ZOOM_PANE_METADATA: CommandMetadata = CommandMetadata {
    name: "zoom-pane",
    since: 6,
    capability: None,
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const AGENT_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "agent-changed",
    since: 11,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const BELL_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "bell",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const BROWSER_STATE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "browser-state",
    since: 6,
    capability: None,
    streams: &["attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLIENT_ATTACHED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "client-attached",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLIENT_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "client-changed",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLIENT_DETACHED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "client-detached",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLIENT_LIST_INVALIDATED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "client-list-invalidated",
    since: 9,
    capability: None,
    streams: &["subscribe"],
    emission: "serialized-never-emitted",
};

#[rustfmt::skip]
pub const COLORS_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "colors-changed",
    since: 6,
    capability: None,
    streams: &["attach-byte"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CONFIG_RELOAD_REQUESTED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "config-reload-requested",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const DETACHED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "detached",
    since: 5,
    capability: None,
    streams: &["attach-byte", "attach-render", "attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const EMPTY_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "empty",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const FRAME_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "frame",
    since: 6,
    capability: None,
    streams: &["attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const FRONTEND_PROJECTION_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "frontend-projection-changed",
    since: 7,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const GRAPHICS_STATUS_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "graphics-status",
    since: 10,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const LAYOUT_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "layout-changed",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const NOTIFICATION_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "notification",
    since: 6,
    capability: None,
    streams: &["subscribe", "attach-byte", "attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const OUTPUT_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "output",
    since: 5,
    capability: None,
    streams: &["attach-byte"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const OVERFLOW_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "overflow",
    since: 7,
    capability: None,
    streams: &["subscribe", "attach-byte", "attach-render", "attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const PAIRING_REQUESTED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "pairing-requested",
    since: 7,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const PAIRING_RESOLVED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "pairing-resolved",
    since: 7,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const PANE_ADDED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "pane-added",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const PANE_CLOSED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "pane-closed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const RENDER_DELTA_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "render-delta",
    since: 7,
    capability: None,
    streams: &["attach-render"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const RENDER_STATE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "render-state",
    since: 7,
    capability: None,
    streams: &["attach-render"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const RESIZED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "resized",
    since: 6,
    capability: None,
    streams: &["attach-byte"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SCREEN_ADDED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "screen-added",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SCREEN_CLOSED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "screen-closed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SCREEN_RENAMED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "screen-renamed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SCROLL_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "scroll-changed",
    since: 6,
    capability: None,
    streams: &["subscribe", "attach-byte", "attach-render", "attach-browser"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const STATUS_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "status",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SURFACE_EXITED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "surface-exited",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SURFACE_OUTPUT_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "surface-output",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SURFACE_RESIZE_FAILED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "surface-resize-failed",
    since: 7,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const SURFACE_RESIZED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "surface-resized",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TAB_ADDED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "tab-added",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TAB_CLOSED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "tab-closed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TAB_RENAMED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "tab-renamed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TERMINAL_REGISTRY_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "terminal-registry-changed",
    since: 9,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TITLE_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "title-changed",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TREE_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "tree-changed",
    since: 5,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const VT_STATE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "vt-state",
    since: 5,
    capability: None,
    streams: &["attach-byte"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const WINDOW_TITLE_REQUESTED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "window-title-requested",
    since: 6,
    capability: None,
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const WORKSPACE_ADDED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "workspace-added",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const WORKSPACE_CLOSED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "workspace-closed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const WORKSPACE_MOVED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "workspace-moved",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const WORKSPACE_RENAMED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "workspace-renamed",
    since: 7,
    capability: None,
    streams: &["subscribe-deltas"],
    emission: "emitted",
};

#[rustfmt::skip]
pub static PROFILES: &[ProfileMetadata] = &[CONTROL_PROFILE, FRONTEND_PROFILE, LOCAL_ADMIN_PROFILE, PROVIDER_AUTHORITY_PROFILE];
#[rustfmt::skip]
pub static COMMANDS: &[CommandMetadata] = &[APPLY_LAYOUT_METADATA, ATTACH_SURFACE_METADATA, BROWSER_ACTIVATE_METADATA, BROWSER_BACK_METADATA, BROWSER_FORWARD_METADATA, BROWSER_FRAME_PRESENTED_METADATA, BROWSER_INSERT_TEXT_METADATA, BROWSER_KEY_METADATA, BROWSER_KEY_PRESS_METADATA, BROWSER_MOUSE_METADATA, BROWSER_MOUSE_GUARDED_METADATA, BROWSER_NAVIGATE_METADATA, BROWSER_RELOAD_METADATA, BROWSER_WHEEL_METADATA, BROWSER_WHEEL_GUARDED_METADATA, CLEAR_HISTORY_METADATA, CLEAR_WINDOW_TITLE_METADATA, CLIENT_FOCUS_METADATA, CLOSE_PANE_METADATA, CLOSE_PROVIDER_MANAGED_WORKSPACE_METADATA, CLOSE_SCREEN_METADATA, CLOSE_SURFACE_METADATA, CLOSE_TERMINAL_METADATA, CLOSE_WORKSPACE_METADATA, COPY_METADATA, CREATE_SURFACE_WITH_RECEIPT_METADATA, CREATE_TERMINAL_METADATA, CREATE_WORKSPACE_METADATA, DETACH_ATTACHED_VIEW_METADATA, DETACH_CLIENT_METADATA, EXPORT_LAYOUT_METADATA, FOCUS_DIRECTION_METADATA, FOCUS_PANE_METADATA, GET_BROWSER_PROVIDER_METADATA, GET_CELL_PIXELS_METADATA, GET_FRONTEND_PROJECTION_METADATA, IDENTIFY_METADATA, IDS_METADATA, JOURNAL_FRONTEND_EVENT_METADATA, LIST_AGENTS_METADATA, LIST_CLIENTS_METADATA, LIST_TERMINALS_METADATA, LIST_WORKSPACES_METADATA, MARK_WORKSPACES_PROVIDER_MANAGED_METADATA, MINT_TERMINAL_RENDERER_METADATA, MINT_TERMINAL_RENDERER_BY_TERMINAL_METADATA, MOVE_TAB_METADATA, MOVE_TERMINAL_METADATA, MOVE_WORKSPACE_METADATA, NEW_BROWSER_TAB_METADATA, NEW_PANE_METADATA, NEW_PANE_RIGHT_METADATA, NEW_SCREEN_METADATA, NEW_TAB_METADATA, NEW_WORKSPACE_METADATA, NOTIFY_METADATA, PAIRING_RESPONSE_METADATA, PANE_NEIGHBOR_METADATA, PING_METADATA, PROCESS_INFO_METADATA, PUT_FRONTEND_PROJECTION_METADATA, READ_SCREEN_METADATA, READ_SCROLLBACK_METADATA, REGISTER_BROWSER_PROVIDER_METADATA, RELEASE_ATTACHED_VIEW_SIZE_METADATA, RELEASE_SURFACE_SIZE_METADATA, RELOAD_CONFIG_METADATA, RENAME_PANE_METADATA, RENAME_PROVIDER_MANAGED_WORKSPACE_METADATA, RENAME_SCREEN_METADATA, RENAME_SURFACE_METADATA, RENAME_WORKSPACE_METADATA, REPORT_AGENT_METADATA, REPORT_FOCUS_METADATA, RESIZE_ATTACHED_VIEW_METADATA, RESIZE_SURFACE_METADATA, RESOLVE_TERMINAL_METADATA, RUN_METADATA, SCROLL_SURFACE_METADATA, SELECT_SCREEN_METADATA, SELECT_TAB_METADATA, SELECT_WORKSPACE_METADATA, SEND_METADATA, SEND_KEY_METADATA, SET_CELL_PIXELS_METADATA, SET_CLIENT_INFO_METADATA, SET_CLIENT_SIZING_METADATA, SET_DEFAULT_COLORS_METADATA, SET_RATIO_METADATA, SET_SPLIT_RATIO_METADATA, SET_VIEWPORT_PANE_WIDTH_METADATA, SET_WINDOW_TITLE_METADATA, SHUTDOWN_DAEMON_METADATA, SIDEBAR_PLUGIN_METADATA, SPLIT_METADATA, SUBSCRIBE_METADATA, SWAP_PANE_METADATA, TERMINAL_EVENTS_METADATA, UNDO_LAYOUT_METADATA, UNREGISTER_BROWSER_PROVIDER_METADATA, VT_STATE_METADATA, WAIT_FOR_METADATA, ZOOM_PANE_METADATA];
#[rustfmt::skip]
pub static EVENTS: &[EventMetadata] = &[AGENT_CHANGED_EVENT_METADATA, BELL_EVENT_METADATA, BROWSER_STATE_EVENT_METADATA, CLIENT_ATTACHED_EVENT_METADATA, CLIENT_CHANGED_EVENT_METADATA, CLIENT_DETACHED_EVENT_METADATA, CLIENT_LIST_INVALIDATED_EVENT_METADATA, COLORS_CHANGED_EVENT_METADATA, CONFIG_RELOAD_REQUESTED_EVENT_METADATA, DETACHED_EVENT_METADATA, EMPTY_EVENT_METADATA, FRAME_EVENT_METADATA, FRONTEND_PROJECTION_CHANGED_EVENT_METADATA, GRAPHICS_STATUS_EVENT_METADATA, LAYOUT_CHANGED_EVENT_METADATA, NOTIFICATION_EVENT_METADATA, OUTPUT_EVENT_METADATA, OVERFLOW_EVENT_METADATA, PAIRING_REQUESTED_EVENT_METADATA, PAIRING_RESOLVED_EVENT_METADATA, PANE_ADDED_EVENT_METADATA, PANE_CLOSED_EVENT_METADATA, RENDER_DELTA_EVENT_METADATA, RENDER_STATE_EVENT_METADATA, RESIZED_EVENT_METADATA, SCREEN_ADDED_EVENT_METADATA, SCREEN_CLOSED_EVENT_METADATA, SCREEN_RENAMED_EVENT_METADATA, SCROLL_CHANGED_EVENT_METADATA, STATUS_EVENT_METADATA, SURFACE_EXITED_EVENT_METADATA, SURFACE_OUTPUT_EVENT_METADATA, SURFACE_RESIZE_FAILED_EVENT_METADATA, SURFACE_RESIZED_EVENT_METADATA, TAB_ADDED_EVENT_METADATA, TAB_CLOSED_EVENT_METADATA, TAB_RENAMED_EVENT_METADATA, TERMINAL_REGISTRY_CHANGED_EVENT_METADATA, TITLE_CHANGED_EVENT_METADATA, TREE_CHANGED_EVENT_METADATA, VT_STATE_EVENT_METADATA, WINDOW_TITLE_REQUESTED_EVENT_METADATA, WORKSPACE_ADDED_EVENT_METADATA, WORKSPACE_CLOSED_EVENT_METADATA, WORKSPACE_MOVED_EVENT_METADATA, WORKSPACE_RENAMED_EVENT_METADATA];

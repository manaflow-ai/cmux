// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR 176aa0cece7a9c80c8dd811192b161cf3264a86b77297ab88990744aa457bafc.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use crate::{CommandMetadata, EventMetadata, ProfileMetadata, StreamMetadata};

pub const SDK_SCHEMA_VERSION: u32 = 2;
pub const MUX_PROTOCOL_VERSION: u32 = 12;
pub const SDK_IR_SHA256: &str = "176aa0cece7a9c80c8dd811192b161cf3264a86b77297ab88990744aa457bafc";

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
pub const ACK_TAB_NOTIFICATIONS_METADATA: CommandMetadata = CommandMetadata {
    name: "ack-tab-notifications",
    since: 12,
    capability: Some("notification-ack-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const ADD_SCREENS_TO_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "add-screens-to-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const ADD_TABS_TO_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "add-tabs-to-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
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
pub const BIND_CONVERSATION_TAB_SESSION_METADATA: CommandMetadata = CommandMetadata {
    name: "bind-conversation-tab-session",
    since: 12,
    capability: Some("agent-session-tabs-v1"),
    authority: "control",
    stream: None,
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
pub const BROWSER_HOST_PROVIDER_METADATA: CommandMetadata = CommandMetadata {
    name: "browser-host-provider",
    since: 12,
    capability: Some("browser-host-provider-v1"),
    authority: "local-admin",
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
pub const CHIEF_INSPECT_METADATA: CommandMetadata = CommandMetadata {
    name: "chief-inspect",
    since: 12,
    capability: Some("chief-inspect-v1"),
    authority: "local-admin",
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
pub const CLOSE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "close-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
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
pub const CLOSE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "close-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CLOSE_TABS_METADATA: CommandMetadata = CommandMetadata {
    name: "close-tabs",
    since: 12,
    capability: Some("batch-close-v1"),
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
pub const CLOUD_CONVERSATION_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-conversation-history",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_CONVERSATION_OP_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-conversation-op",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_CONVERSATION_SNAPSHOT_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-conversation-snapshot",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_CONVERSATION_SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-conversation-subscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_CONVERSATION_UNSUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-conversation-unsubscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_INBOX_LIST_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-inbox-list",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_INBOX_SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-inbox-subscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_INBOX_UNSUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-inbox-unsubscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_MUX_ACK_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-mux-ack",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_MUX_SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-mux-subscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_MUX_UNSUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-mux-unsubscribe",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_SESSION_CLEAR_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-session-clear",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_SESSION_SET_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-session-set",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CLOUD_SESSION_STATUS_METADATA: CommandMetadata = CommandMetadata {
    name: "cloud-session-status",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_AGENT_TOKEN_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-agent-token",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_ATTACHMENT_READ_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-attachment-read",
    since: 12,
    capability: Some("local-attachments-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_ATTACHMENT_UPLOAD_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-attachment-upload",
    since: 12,
    capability: Some("local-attachments-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_BIND_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-bind",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_CREATE_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-create",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-history",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_IMPORT_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-import",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_LIST_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-list",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_OP_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-op",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_SEARCH_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-search",
    since: 12,
    capability: Some("conversation-search-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_SNAPSHOT_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-snapshot",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const CONVERSATION_TYPING_METADATA: CommandMetadata = CommandMetadata {
    name: "conversation-typing",
    since: 12,
    capability: Some("local-conversations-v1"),
    authority: "local-admin",
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
pub const CREATE_BOOKMARK_METADATA: CommandMetadata = CommandMetadata {
    name: "create-bookmark",
    since: 12,
    capability: Some("bookmarks-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_BROWSER_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "create-browser-profile",
    since: 12,
    capability: Some("browser-profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_PERSONAL_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "create-personal-group",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "create-profile",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const CREATE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "create-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
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
pub const CREATE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "create-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
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
pub const CREATE_WORKSPACE_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "create-workspace-group",
    since: 12,
    capability: Some("workspace-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_BOOKMARK_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-bookmark",
    since: 12,
    capability: Some("bookmarks-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_BROWSER_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-browser-profile",
    since: 12,
    capability: Some("browser-profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_PERSONAL_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-personal-group",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-profile",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_SAVED_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-saved-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_SAVED_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-saved-tab-group",
    since: 12,
    capability: Some("saved-tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const DELETE_WORKSPACE_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "delete-workspace-group",
    since: 12,
    capability: Some("workspace-groups-v1"),
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
pub const FORGET_SESSION_METADATA: CommandMetadata = CommandMetadata {
    name: "forget-session",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const GET_FRONTEND_BROWSER_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "get-frontend-browser-history",
    since: 12,
    capability: Some("frontend-browser-history-v1"),
    authority: "control",
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
pub const GET_SIZE_STATE_METADATA: CommandMetadata = CommandMetadata {
    name: "get-size-state",
    since: 12,
    capability: Some("shared-sizing-v1"),
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
pub const IMPORT_BOOKMARKS_METADATA: CommandMetadata = CommandMetadata {
    name: "import-bookmarks",
    since: 12,
    capability: Some("bookmarks-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const IMPORT_SESSION_ORGANIZATION_METADATA: CommandMetadata = CommandMetadata {
    name: "import-session-organization",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const LIST_BOOKMARKS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-bookmarks",
    since: 12,
    capability: Some("bookmarks-v1"),
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
pub const LIST_NOTIFICATIONS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-notifications",
    since: 12,
    capability: Some("notification-ack-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_PERSONAL_METADATA: CommandMetadata = CommandMetadata {
    name: "list-personal",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_SAVED_SCREEN_GROUPS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-saved-screen-groups",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_SAVED_TAB_GROUPS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-saved-tab-groups",
    since: 12,
    capability: Some("saved-tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const LIST_TAB_GROUPS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-tab-groups",
    since: 12,
    capability: Some("tab-groups-v1"),
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
pub const LIST_WORKSPACE_GROUPS_METADATA: CommandMetadata = CommandMetadata {
    name: "list-workspace-groups",
    since: 12,
    capability: Some("workspace-groups-v1"),
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
pub const MACHINE_LISTENING_TCP_METADATA: CommandMetadata = CommandMetadata {
    name: "machine-listening-tcp",
    since: 12,
    capability: Some("machine-listening-tcp-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MACHINE_USAGE_METADATA: CommandMetadata = CommandMetadata {
    name: "machine-usage",
    since: 12,
    capability: Some("machine-usage-v1"),
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
pub const MOVE_BOOKMARK_METADATA: CommandMetadata = CommandMetadata {
    name: "move-bookmark",
    since: 12,
    capability: Some("bookmarks-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_BROWSER_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-browser-profile",
    since: 12,
    capability: Some("browser-profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_PERSONAL_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "move-personal-group",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-profile",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_SCREEN_METADATA: CommandMetadata = CommandMetadata {
    name: "move-screen",
    since: 12,
    capability: Some("screen-metadata-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "move-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
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
pub const MOVE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_GROUP_TO_COLUMN_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-group-to-column",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_GROUP_TO_NEW_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-group-to-new-workspace",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_GROUP_TO_SPLIT_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-group-to-split",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_TO_COLUMN_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-to-column",
    since: 12,
    capability: Some("tab-drag-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_TO_NEW_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-to-new-workspace",
    since: 12,
    capability: Some("tab-drag-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_TO_SPLIT_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-to-split",
    since: 12,
    capability: Some("tab-drag-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_TAB_TO_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "move-tab-to-workspace",
    since: 12,
    capability: Some("tab-workspace-move-v1"),
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
pub const MOVE_WORKSPACE_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "move-workspace-group",
    since: 12,
    capability: Some("workspace-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const MOVE_WORKSPACE_TO_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "move-workspace-to-group",
    since: 12,
    capability: Some("workspace-groups-v1"),
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
pub const NEW_CONVERSATION_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "new-conversation-tab",
    since: 12,
    capability: Some("conversation-tabs-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const NEW_FRONTEND_BROWSER_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "new-frontend-browser-tab",
    since: 12,
    capability: Some("frontend-browser-tabs-v1"),
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
pub const NEW_ROW_METADATA: CommandMetadata = CommandMetadata {
    name: "new-row",
    since: 12,
    capability: Some("rows-v1"),
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
pub const NOTE_SIZE_ACTIVITY_METADATA: CommandMetadata = CommandMetadata {
    name: "note-size-activity",
    since: 12,
    capability: Some("shared-sizing-v1"),
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
pub const PASTE_IMAGE_METADATA: CommandMetadata = CommandMetadata {
    name: "paste-image",
    since: 12,
    capability: Some("terminal-image-paste-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const PIN_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "pin-workspace",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const PUT_SESSION_METADATA: CommandMetadata = CommandMetadata {
    name: "put-session",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const REATTACH_VIEW_METADATA: CommandMetadata = CommandMetadata {
    name: "reattach-view",
    since: 12,
    capability: Some("sizing-view-detach-v1"),
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
pub const REMOVE_SCREENS_FROM_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "remove-screens-from-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const REMOVE_TABS_FROM_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "remove-tabs-from-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
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
pub const REOPEN_SAVED_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "reopen-saved-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const REOPEN_SAVED_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "reopen-saved-tab-group",
    since: 12,
    capability: Some("saved-tab-groups-v1"),
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
pub const SAVE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "save-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SAVE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "save-tab-group",
    since: 12,
    capability: Some("saved-tab-groups-v1"),
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
pub const SERVER_STATS_METADATA: CommandMetadata = CommandMetadata {
    name: "server-stats",
    since: 12,
    capability: Some("server-stats-v1"),
    authority: "local-admin",
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
pub const SET_COLUMN_DOCK_METADATA: CommandMetadata = CommandMetadata {
    name: "set-column-dock",
    since: 12,
    capability: Some("dock-columns-v1"),
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
pub const SET_FRONTEND_BROWSER_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "set-frontend-browser-history",
    since: 12,
    capability: Some("frontend-browser-history-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_PERSONAL_TERMINAL_METADATA: CommandMetadata = CommandMetadata {
    name: "set-personal-terminal",
    since: 12,
    capability: Some("personal-terminals-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_PERSONAL_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "set-personal-workspace",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_PROFILE_FOLLOWS_METADATA: CommandMetadata = CommandMetadata {
    name: "set-profile-follows",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const SET_ROW_HEIGHTS_METADATA: CommandMetadata = CommandMetadata {
    name: "set-row-heights",
    since: 12,
    capability: Some("rows-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_SCREEN_METADATA_METADATA: CommandMetadata = CommandMetadata {
    name: "set-screen-metadata",
    since: 12,
    capability: Some("screen-metadata-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_SCREEN_PINNED_METADATA: CommandMetadata = CommandMetadata {
    name: "set-screen-pinned",
    since: 12,
    capability: Some("screen-metadata-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_SIZE_COUNTS_METADATA: CommandMetadata = CommandMetadata {
    name: "set-size-counts",
    since: 12,
    capability: Some("shared-sizing-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_SIZE_POLICY_METADATA: CommandMetadata = CommandMetadata {
    name: "set-size-policy",
    since: 12,
    capability: Some("shared-sizing-v1"),
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
pub const SET_TAB_PINNED_METADATA: CommandMetadata = CommandMetadata {
    name: "set-tab-pinned",
    since: 12,
    capability: Some("tab-metadata-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_TERMINAL_COMMAND_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "set-terminal-command-history",
    since: 12,
    capability: Some("terminal-command-journal-v1"),
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const SET_TERMINAL_IDLE_POLICY_METADATA: CommandMetadata = CommandMetadata {
    name: "set-terminal-idle-policy",
    since: 12,
    capability: Some("terminal-idle-close-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const SET_TERMINAL_KEEP_METADATA: CommandMetadata = CommandMetadata {
    name: "set-terminal-keep",
    since: 12,
    capability: Some("terminal-reap-v1"),
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
pub const SET_WORKSPACE_METADATA_METADATA: CommandMetadata = CommandMetadata {
    name: "set-workspace-metadata",
    since: 12,
    capability: Some("workspace-metadata-v1"),
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
pub const SNAPSHOT_REQUEST_METADATA: CommandMetadata = CommandMetadata {
    name: "snapshot-request",
    since: 12,
    capability: Some("terminal-snapshot-v1"),
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
pub const SUBSCRIBE_ACTIVITY_METADATA: CommandMetadata = CommandMetadata {
    name: "subscribe-activity",
    since: 12,
    capability: Some("vm-activity-v1"),
    authority: "local-admin",
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
pub const TERMINAL_CLIPBOARD_REPLY_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-clipboard-reply",
    since: 12,
    capability: Some("terminal-clipboard-read-v1"),
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const TERMINAL_CLIPBOARD_SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-clipboard-subscribe",
    since: 12,
    capability: Some("terminal-clipboard-read-v1"),
    authority: "frontend",
    stream: Some(StreamMetadata { kind: "subscribe", terminal_event: None }),
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
pub const TERMINAL_HISTORY_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-history",
    since: 12,
    capability: Some("terminal-snapshot-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const TERMINAL_READ_RANGE_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-read-range",
    since: 12,
    capability: Some("terminal-snapshot-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const TERMINAL_RESOURCES_METADATA: CommandMetadata = CommandMetadata {
    name: "terminal-resources",
    since: 12,
    capability: Some("terminal-resources-v1"),
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
pub const UNGROUP_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "ungroup-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UNGROUP_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "ungroup-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UNPIN_WORKSPACE_METADATA: CommandMetadata = CommandMetadata {
    name: "unpin-workspace",
    since: 12,
    capability: Some("profiles-v1"),
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
pub const UNSAVE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "unsave-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UNSAVE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "unsave-tab-group",
    since: 12,
    capability: Some("saved-tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_BOOKMARK_METADATA: CommandMetadata = CommandMetadata {
    name: "update-bookmark",
    since: 12,
    capability: Some("bookmarks-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_BROWSER_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "update-browser-profile",
    since: 12,
    capability: Some("browser-profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_FRONTEND_BROWSER_TAB_METADATA: CommandMetadata = CommandMetadata {
    name: "update-frontend-browser-tab",
    since: 12,
    capability: Some("frontend-browser-tabs-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_PERSONAL_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "update-personal-group",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_PROFILE_METADATA: CommandMetadata = CommandMetadata {
    name: "update-profile",
    since: 12,
    capability: Some("profiles-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_SCREEN_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "update-screen-group",
    since: 12,
    capability: Some("screen-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_TAB_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "update-tab-group",
    since: 12,
    capability: Some("tab-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const UPDATE_WORKSPACE_GROUP_METADATA: CommandMetadata = CommandMetadata {
    name: "update-workspace-group",
    since: 12,
    capability: Some("workspace-groups-v1"),
    authority: "control",
    stream: None,
};

#[rustfmt::skip]
pub const URL_OPEN_METADATA: CommandMetadata = CommandMetadata {
    name: "url-open",
    since: 12,
    capability: None,
    authority: "local-admin",
    stream: None,
};

#[rustfmt::skip]
pub const URL_OPEN_CLAIM_METADATA: CommandMetadata = CommandMetadata {
    name: "url-open-claim",
    since: 12,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const URL_OPEN_RESULT_METADATA: CommandMetadata = CommandMetadata {
    name: "url-open-result",
    since: 12,
    capability: None,
    authority: "frontend",
    stream: None,
};

#[rustfmt::skip]
pub const URL_OPEN_SUBSCRIBE_METADATA: CommandMetadata = CommandMetadata {
    name: "url-open-subscribe",
    since: 12,
    capability: None,
    authority: "frontend",
    stream: Some(StreamMetadata { kind: "subscribe", terminal_event: None }),
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
pub const ACTIVITY_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "activity-changed",
    since: 12,
    capability: Some("vm-activity-v1"),
    streams: &["control"],
    emission: "emitted",
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
pub const BOOKMARKS_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "bookmarks-changed",
    since: 12,
    capability: Some("bookmarks-v1"),
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
pub const CLOUD_CONVERSATION_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-conversation-changed",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_CONVERSATION_RESYNCED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-conversation-resynced",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_INBOX_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-inbox-changed",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_INBOX_RESET_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-inbox-reset",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_MUX_RESYNCED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-mux-resynced",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_MUX_WAKE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-mux-wake",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_SESSION_NEEDED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-session-needed",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CLOUD_SUBSCRIPTION_STATE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "cloud-subscription-state",
    since: 12,
    capability: Some("cloud-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
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
pub const CONVERSATION_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "conversation-changed",
    since: 12,
    capability: Some("local-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const CONVERSATION_TYPING_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "conversation-typing",
    since: 12,
    capability: Some("local-conversations-v1"),
    streams: &["subscribe"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const DAEMON_SHUTDOWN_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "daemon-shutdown",
    since: 12,
    capability: None,
    streams: &["control"],
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
pub const MACHINE_USAGE_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "machine-usage-changed",
    since: 12,
    capability: Some("machine-usage-v1"),
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
pub const PERSONAL_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "personal-changed",
    since: 12,
    capability: Some("profiles-v1"),
    streams: &["subscribe"],
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
pub const SCREEN_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "screen-changed",
    since: 12,
    capability: Some("screen-metadata-v1"),
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
pub const SIZE_STATE_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "size-state",
    since: 12,
    capability: Some("shared-sizing-v1"),
    streams: &["subscribe", "attach-byte", "attach-render"],
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
pub const TAB_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "tab-changed",
    since: 12,
    capability: Some("tab-metadata-v1"),
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
pub const TERMINAL_CLIPBOARD_READ_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "terminal-clipboard-read",
    since: 12,
    capability: Some("terminal-clipboard-read-v1"),
    streams: &["control"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TERMINAL_CLIPBOARD_READ_CANCELLED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "terminal-clipboard-read-cancelled",
    since: 12,
    capability: Some("terminal-clipboard-read-v1"),
    streams: &["control"],
    emission: "emitted",
};

#[rustfmt::skip]
pub const TERMINAL_REAPED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "terminal-reaped",
    since: 12,
    capability: Some("terminal-reap-v1"),
    streams: &["subscribe"],
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
pub const URL_OPEN_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "url-open",
    since: 12,
    capability: None,
    streams: &["control"],
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
pub const WORKSPACE_CHANGED_EVENT_METADATA: EventMetadata = EventMetadata {
    name: "workspace-changed",
    since: 12,
    capability: Some("workspace-metadata-v1"),
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
pub static COMMANDS: &[CommandMetadata] = &[ACK_TAB_NOTIFICATIONS_METADATA, ADD_SCREENS_TO_SCREEN_GROUP_METADATA, ADD_TABS_TO_TAB_GROUP_METADATA, APPLY_LAYOUT_METADATA, ATTACH_SURFACE_METADATA, BIND_CONVERSATION_TAB_SESSION_METADATA, BROWSER_ACTIVATE_METADATA, BROWSER_BACK_METADATA, BROWSER_FORWARD_METADATA, BROWSER_FRAME_PRESENTED_METADATA, BROWSER_HOST_PROVIDER_METADATA, BROWSER_INSERT_TEXT_METADATA, BROWSER_KEY_METADATA, BROWSER_KEY_PRESS_METADATA, BROWSER_MOUSE_METADATA, BROWSER_MOUSE_GUARDED_METADATA, BROWSER_NAVIGATE_METADATA, BROWSER_RELOAD_METADATA, BROWSER_WHEEL_METADATA, BROWSER_WHEEL_GUARDED_METADATA, CHIEF_INSPECT_METADATA, CLEAR_HISTORY_METADATA, CLEAR_WINDOW_TITLE_METADATA, CLIENT_FOCUS_METADATA, CLOSE_PANE_METADATA, CLOSE_PROVIDER_MANAGED_WORKSPACE_METADATA, CLOSE_SCREEN_METADATA, CLOSE_SCREEN_GROUP_METADATA, CLOSE_SURFACE_METADATA, CLOSE_TAB_GROUP_METADATA, CLOSE_TABS_METADATA, CLOSE_TERMINAL_METADATA, CLOSE_WORKSPACE_METADATA, CLOUD_CONVERSATION_HISTORY_METADATA, CLOUD_CONVERSATION_OP_METADATA, CLOUD_CONVERSATION_SNAPSHOT_METADATA, CLOUD_CONVERSATION_SUBSCRIBE_METADATA, CLOUD_CONVERSATION_UNSUBSCRIBE_METADATA, CLOUD_INBOX_LIST_METADATA, CLOUD_INBOX_SUBSCRIBE_METADATA, CLOUD_INBOX_UNSUBSCRIBE_METADATA, CLOUD_MUX_ACK_METADATA, CLOUD_MUX_SUBSCRIBE_METADATA, CLOUD_MUX_UNSUBSCRIBE_METADATA, CLOUD_SESSION_CLEAR_METADATA, CLOUD_SESSION_SET_METADATA, CLOUD_SESSION_STATUS_METADATA, CONVERSATION_AGENT_TOKEN_METADATA, CONVERSATION_ATTACHMENT_READ_METADATA, CONVERSATION_ATTACHMENT_UPLOAD_METADATA, CONVERSATION_BIND_METADATA, CONVERSATION_CREATE_METADATA, CONVERSATION_HISTORY_METADATA, CONVERSATION_IMPORT_METADATA, CONVERSATION_LIST_METADATA, CONVERSATION_OP_METADATA, CONVERSATION_SEARCH_METADATA, CONVERSATION_SNAPSHOT_METADATA, CONVERSATION_TYPING_METADATA, COPY_METADATA, CREATE_BOOKMARK_METADATA, CREATE_BROWSER_PROFILE_METADATA, CREATE_PERSONAL_GROUP_METADATA, CREATE_PROFILE_METADATA, CREATE_SCREEN_GROUP_METADATA, CREATE_SURFACE_WITH_RECEIPT_METADATA, CREATE_TAB_GROUP_METADATA, CREATE_TERMINAL_METADATA, CREATE_WORKSPACE_METADATA, CREATE_WORKSPACE_GROUP_METADATA, DELETE_BOOKMARK_METADATA, DELETE_BROWSER_PROFILE_METADATA, DELETE_PERSONAL_GROUP_METADATA, DELETE_PROFILE_METADATA, DELETE_SAVED_SCREEN_GROUP_METADATA, DELETE_SAVED_TAB_GROUP_METADATA, DELETE_WORKSPACE_GROUP_METADATA, DETACH_ATTACHED_VIEW_METADATA, DETACH_CLIENT_METADATA, EXPORT_LAYOUT_METADATA, FOCUS_DIRECTION_METADATA, FOCUS_PANE_METADATA, FORGET_SESSION_METADATA, GET_BROWSER_PROVIDER_METADATA, GET_CELL_PIXELS_METADATA, GET_FRONTEND_BROWSER_HISTORY_METADATA, GET_FRONTEND_PROJECTION_METADATA, GET_SIZE_STATE_METADATA, IDENTIFY_METADATA, IDS_METADATA, IMPORT_BOOKMARKS_METADATA, IMPORT_SESSION_ORGANIZATION_METADATA, JOURNAL_FRONTEND_EVENT_METADATA, LIST_AGENTS_METADATA, LIST_BOOKMARKS_METADATA, LIST_CLIENTS_METADATA, LIST_NOTIFICATIONS_METADATA, LIST_PERSONAL_METADATA, LIST_SAVED_SCREEN_GROUPS_METADATA, LIST_SAVED_TAB_GROUPS_METADATA, LIST_TAB_GROUPS_METADATA, LIST_TERMINALS_METADATA, LIST_WORKSPACE_GROUPS_METADATA, LIST_WORKSPACES_METADATA, MACHINE_LISTENING_TCP_METADATA, MACHINE_USAGE_METADATA, MARK_WORKSPACES_PROVIDER_MANAGED_METADATA, MINT_TERMINAL_RENDERER_METADATA, MINT_TERMINAL_RENDERER_BY_TERMINAL_METADATA, MOVE_BOOKMARK_METADATA, MOVE_BROWSER_PROFILE_METADATA, MOVE_PERSONAL_GROUP_METADATA, MOVE_PROFILE_METADATA, MOVE_SCREEN_METADATA, MOVE_SCREEN_GROUP_METADATA, MOVE_TAB_METADATA, MOVE_TAB_GROUP_METADATA, MOVE_TAB_GROUP_TO_COLUMN_METADATA, MOVE_TAB_GROUP_TO_NEW_WORKSPACE_METADATA, MOVE_TAB_GROUP_TO_SPLIT_METADATA, MOVE_TAB_TO_COLUMN_METADATA, MOVE_TAB_TO_NEW_WORKSPACE_METADATA, MOVE_TAB_TO_SPLIT_METADATA, MOVE_TAB_TO_WORKSPACE_METADATA, MOVE_TERMINAL_METADATA, MOVE_WORKSPACE_METADATA, MOVE_WORKSPACE_GROUP_METADATA, MOVE_WORKSPACE_TO_GROUP_METADATA, NEW_BROWSER_TAB_METADATA, NEW_CONVERSATION_TAB_METADATA, NEW_FRONTEND_BROWSER_TAB_METADATA, NEW_PANE_METADATA, NEW_PANE_RIGHT_METADATA, NEW_ROW_METADATA, NEW_SCREEN_METADATA, NEW_TAB_METADATA, NEW_WORKSPACE_METADATA, NOTE_SIZE_ACTIVITY_METADATA, NOTIFY_METADATA, PAIRING_RESPONSE_METADATA, PANE_NEIGHBOR_METADATA, PASTE_IMAGE_METADATA, PIN_WORKSPACE_METADATA, PING_METADATA, PROCESS_INFO_METADATA, PUT_FRONTEND_PROJECTION_METADATA, PUT_SESSION_METADATA, READ_SCREEN_METADATA, READ_SCROLLBACK_METADATA, REATTACH_VIEW_METADATA, REGISTER_BROWSER_PROVIDER_METADATA, RELEASE_ATTACHED_VIEW_SIZE_METADATA, RELEASE_SURFACE_SIZE_METADATA, RELOAD_CONFIG_METADATA, REMOVE_SCREENS_FROM_SCREEN_GROUP_METADATA, REMOVE_TABS_FROM_TAB_GROUP_METADATA, RENAME_PANE_METADATA, RENAME_PROVIDER_MANAGED_WORKSPACE_METADATA, RENAME_SCREEN_METADATA, RENAME_SURFACE_METADATA, RENAME_WORKSPACE_METADATA, REOPEN_SAVED_SCREEN_GROUP_METADATA, REOPEN_SAVED_TAB_GROUP_METADATA, REPORT_AGENT_METADATA, REPORT_FOCUS_METADATA, RESIZE_ATTACHED_VIEW_METADATA, RESIZE_SURFACE_METADATA, RESOLVE_TERMINAL_METADATA, RUN_METADATA, SAVE_SCREEN_GROUP_METADATA, SAVE_TAB_GROUP_METADATA, SCROLL_SURFACE_METADATA, SELECT_SCREEN_METADATA, SELECT_TAB_METADATA, SELECT_WORKSPACE_METADATA, SEND_METADATA, SEND_KEY_METADATA, SERVER_STATS_METADATA, SET_CELL_PIXELS_METADATA, SET_CLIENT_INFO_METADATA, SET_CLIENT_SIZING_METADATA, SET_COLUMN_DOCK_METADATA, SET_DEFAULT_COLORS_METADATA, SET_FRONTEND_BROWSER_HISTORY_METADATA, SET_PERSONAL_TERMINAL_METADATA, SET_PERSONAL_WORKSPACE_METADATA, SET_PROFILE_FOLLOWS_METADATA, SET_RATIO_METADATA, SET_ROW_HEIGHTS_METADATA, SET_SCREEN_METADATA_METADATA, SET_SCREEN_PINNED_METADATA, SET_SIZE_COUNTS_METADATA, SET_SIZE_POLICY_METADATA, SET_SPLIT_RATIO_METADATA, SET_TAB_PINNED_METADATA, SET_TERMINAL_COMMAND_HISTORY_METADATA, SET_TERMINAL_IDLE_POLICY_METADATA, SET_TERMINAL_KEEP_METADATA, SET_VIEWPORT_PANE_WIDTH_METADATA, SET_WINDOW_TITLE_METADATA, SET_WORKSPACE_METADATA_METADATA, SHUTDOWN_DAEMON_METADATA, SIDEBAR_PLUGIN_METADATA, SNAPSHOT_REQUEST_METADATA, SPLIT_METADATA, SUBSCRIBE_METADATA, SUBSCRIBE_ACTIVITY_METADATA, SWAP_PANE_METADATA, TERMINAL_CLIPBOARD_REPLY_METADATA, TERMINAL_CLIPBOARD_SUBSCRIBE_METADATA, TERMINAL_EVENTS_METADATA, TERMINAL_HISTORY_METADATA, TERMINAL_READ_RANGE_METADATA, TERMINAL_RESOURCES_METADATA, UNDO_LAYOUT_METADATA, UNGROUP_SCREEN_GROUP_METADATA, UNGROUP_TAB_GROUP_METADATA, UNPIN_WORKSPACE_METADATA, UNREGISTER_BROWSER_PROVIDER_METADATA, UNSAVE_SCREEN_GROUP_METADATA, UNSAVE_TAB_GROUP_METADATA, UPDATE_BOOKMARK_METADATA, UPDATE_BROWSER_PROFILE_METADATA, UPDATE_FRONTEND_BROWSER_TAB_METADATA, UPDATE_PERSONAL_GROUP_METADATA, UPDATE_PROFILE_METADATA, UPDATE_SCREEN_GROUP_METADATA, UPDATE_TAB_GROUP_METADATA, UPDATE_WORKSPACE_GROUP_METADATA, URL_OPEN_METADATA, URL_OPEN_CLAIM_METADATA, URL_OPEN_RESULT_METADATA, URL_OPEN_SUBSCRIBE_METADATA, VT_STATE_METADATA, WAIT_FOR_METADATA, ZOOM_PANE_METADATA];
#[rustfmt::skip]
pub static EVENTS: &[EventMetadata] = &[ACTIVITY_CHANGED_EVENT_METADATA, AGENT_CHANGED_EVENT_METADATA, BELL_EVENT_METADATA, BOOKMARKS_CHANGED_EVENT_METADATA, BROWSER_STATE_EVENT_METADATA, CLIENT_ATTACHED_EVENT_METADATA, CLIENT_CHANGED_EVENT_METADATA, CLIENT_DETACHED_EVENT_METADATA, CLIENT_LIST_INVALIDATED_EVENT_METADATA, CLOUD_CONVERSATION_CHANGED_EVENT_METADATA, CLOUD_CONVERSATION_RESYNCED_EVENT_METADATA, CLOUD_INBOX_CHANGED_EVENT_METADATA, CLOUD_INBOX_RESET_EVENT_METADATA, CLOUD_MUX_RESYNCED_EVENT_METADATA, CLOUD_MUX_WAKE_EVENT_METADATA, CLOUD_SESSION_NEEDED_EVENT_METADATA, CLOUD_SUBSCRIPTION_STATE_EVENT_METADATA, COLORS_CHANGED_EVENT_METADATA, CONFIG_RELOAD_REQUESTED_EVENT_METADATA, CONVERSATION_CHANGED_EVENT_METADATA, CONVERSATION_TYPING_EVENT_METADATA, DAEMON_SHUTDOWN_EVENT_METADATA, DETACHED_EVENT_METADATA, EMPTY_EVENT_METADATA, FRAME_EVENT_METADATA, FRONTEND_PROJECTION_CHANGED_EVENT_METADATA, GRAPHICS_STATUS_EVENT_METADATA, LAYOUT_CHANGED_EVENT_METADATA, MACHINE_USAGE_CHANGED_EVENT_METADATA, NOTIFICATION_EVENT_METADATA, OUTPUT_EVENT_METADATA, OVERFLOW_EVENT_METADATA, PAIRING_REQUESTED_EVENT_METADATA, PAIRING_RESOLVED_EVENT_METADATA, PANE_ADDED_EVENT_METADATA, PANE_CLOSED_EVENT_METADATA, PERSONAL_CHANGED_EVENT_METADATA, RENDER_DELTA_EVENT_METADATA, RENDER_STATE_EVENT_METADATA, RESIZED_EVENT_METADATA, SCREEN_ADDED_EVENT_METADATA, SCREEN_CHANGED_EVENT_METADATA, SCREEN_CLOSED_EVENT_METADATA, SCREEN_RENAMED_EVENT_METADATA, SCROLL_CHANGED_EVENT_METADATA, SIZE_STATE_EVENT_METADATA, STATUS_EVENT_METADATA, SURFACE_EXITED_EVENT_METADATA, SURFACE_OUTPUT_EVENT_METADATA, SURFACE_RESIZE_FAILED_EVENT_METADATA, SURFACE_RESIZED_EVENT_METADATA, TAB_ADDED_EVENT_METADATA, TAB_CHANGED_EVENT_METADATA, TAB_CLOSED_EVENT_METADATA, TAB_RENAMED_EVENT_METADATA, TERMINAL_CLIPBOARD_READ_EVENT_METADATA, TERMINAL_CLIPBOARD_READ_CANCELLED_EVENT_METADATA, TERMINAL_REAPED_EVENT_METADATA, TERMINAL_REGISTRY_CHANGED_EVENT_METADATA, TITLE_CHANGED_EVENT_METADATA, TREE_CHANGED_EVENT_METADATA, URL_OPEN_EVENT_METADATA, VT_STATE_EVENT_METADATA, WINDOW_TITLE_REQUESTED_EVENT_METADATA, WORKSPACE_ADDED_EVENT_METADATA, WORKSPACE_CHANGED_EVENT_METADATA, WORKSPACE_CLOSED_EVENT_METADATA, WORKSPACE_MOVED_EVENT_METADATA, WORKSPACE_RENAMED_EVENT_METADATA];

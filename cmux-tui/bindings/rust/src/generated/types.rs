// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 10, IR 2006a175f8506aeeca40689c7a61651a6685a7b03b3c9c52c38cd5259c3a9a96.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use crate::{Nullable, Optional};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[rustfmt::skip]
pub type Base64 = String;
#[rustfmt::skip]
pub type ColorHex = String;
#[rustfmt::skip]
pub type Id = u64;
#[rustfmt::skip]
pub type JsonValue = serde_json::Value;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentRecord {
    pub session: Nullable<String>,
    pub source: AgentSource,
    pub state: AgentState,
    pub surface: Id,
    pub updated_at_ms: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentReportSource {
    #[serde(rename = "socket")]
    Socket,
    #[serde(rename = "hook")]
    Hook,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentSource {
    #[serde(rename = "detected")]
    Detected,
    #[serde(rename = "socket")]
    Socket,
    #[serde(rename = "hook")]
    Hook,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgentState {
    #[serde(rename = "working")]
    Working,
    #[serde(rename = "blocked")]
    Blocked,
    #[serde(rename = "idle")]
    Idle,
    #[serde(rename = "done")]
    Done,
    #[serde(rename = "unknown")]
    Unknown,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppliedPane {
    pub pane: Id,
    pub surface: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApplyLayoutResult {
    pub panes: Vec<AppliedPane>,
    pub screen: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserFrame {
    pub data: Base64,
    pub height: u32,
    pub seq: u64,
    pub width: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CellPixelFailure {
    pub error: String,
    pub surface: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CellPixelResize {
    pub cols: u16,
    pub reservation_id: u64,
    pub rows: u16,
    pub surface: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientInfo {
    pub attached: Vec<Id>,
    pub client: u64,
    pub connected_seconds: u64,
    pub kind: Nullable<String>,
    pub name: Nullable<String>,
    #[serde(rename = "self")]
    pub self_: bool,
    pub sizes: Vec<ClientSize>,
    pub transport: ClientTransport,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientSize {
    pub cols: Nullable<u16>,
    pub rows: Nullable<u16>,
    pub size_participating: bool,
    pub surface: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClientTransport {
    #[serde(rename = "local")]
    Local,
    #[serde(rename = "unix")]
    Unix,
    #[serde(rename = "ws")]
    Ws,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseTerminalResult {
    pub already_closed: bool,
    pub closed: bool,
    pub generation: String,
    pub registry_id: String,
    pub surface: Nullable<Id>,
    pub terminal_id: String,
    pub terminal_incarnation: Nullable<String>,
    pub terminal_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CopyResultMode {
    #[serde(rename = "screen")]
    Screen,
    #[serde(rename = "selection")]
    Selection,
    #[serde(rename = "scrollback")]
    Scrollback,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CopyResult {
    pub mode: CopyResultMode,
    pub text: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CursorStyle {
    #[serde(rename = "block")]
    Block,
    #[serde(rename = "underline")]
    Underline,
    #[serde(rename = "bar")]
    Bar,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeadPane {
    pub dead: bool,
    pub id: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum DeclarativeLayout {
    #[serde(rename = "leaf")]
    Leaf {
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        command: Optional<Vec<String>>,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        cwd: Optional<String>,
    },
    #[serde(rename = "split")]
    Split {
        a: Box<DeclarativeLayout>,
        b: Box<DeclarativeLayout>,
        dir: SplitDirection,
        ratio: f32,
    },
    #[serde(rename = "stack")]
    Stack {
        expanded: Id,
        panes: Vec<Id>,
    },
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct EmptyResult {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportLayoutResult {
    pub layout: Layout,
    pub panes: Vec<ExportedPane>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportedPane {
    pub pane: Id,
    pub surfaces: Vec<Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusDirectionResult {
    pub pane: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrontendProjection {
    pub frontend: String,
    pub projection: Nullable<JsonValue>,
    pub projection_revision: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub replayed: Option<bool>,
    pub schema_version: u32,
    pub scope: String,
    pub subject_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum IdMappingKind {
    #[serde(rename = "workspace")]
    Workspace,
    #[serde(rename = "screen")]
    Screen,
    #[serde(rename = "pane")]
    Pane,
    #[serde(rename = "surface")]
    Surface,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IdMapping {
    pub id: Id,
    pub kind: IdMappingKind,
    pub short_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IdentifyResult {
    pub app: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub build_commit: Optional<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<String>>,
    pub daemon_handoff: u64,
    pub generation: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub ghostty_commit: Optional<String>,
    pub pid: u32,
    pub protocol: u32,
    pub registry_id: String,
    pub session: String,
    pub terminal_revision: u64,
    pub version: String,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IdsResult {
    pub ids: Vec<IdMapping>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Layout {
    #[serde(rename = "leaf")]
    Leaf {
        pane: Id,
    },
    #[serde(rename = "split")]
    Split {
        a: Box<Layout>,
        b: Box<Layout>,
        dir: SplitDirection,
        ratio: f32,
        #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
        split: Option<Id>,
    },
    #[serde(rename = "stack")]
    Stack {
        expanded: Id,
        panes: Vec<Id>,
    },
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListAgentsResult {
    pub agents: Vec<AgentRecord>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListTerminalsResult {
    pub generation: String,
    pub registry_id: String,
    pub terminal_revision: u64,
    pub terminals: Vec<TerminalRecord>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LivePane {
    pub active_tab: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub focused_at: Option<u64>,
    pub id: Id,
    pub name: Nullable<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub short_id: Option<String>,
    pub tabs: Vec<Tab>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MintTerminalRendererResult {
    pub endpoint: String,
    pub incarnation: String,
    pub rights: u32,
    pub terminal_id: String,
    pub token: String,
    pub ttl_ms: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTerminalResult {
    pub changed: bool,
    pub generation: String,
    pub lifecycle: TerminalLifecycle,
    pub pane: Nullable<Id>,
    pub registry_id: String,
    pub replayed: bool,
    pub screen: Nullable<Id>,
    pub surface: Nullable<Id>,
    pub terminal_id: String,
    pub terminal_incarnation: Nullable<String>,
    pub terminal_revision: u64,
    pub workspace: Nullable<Id>,
    pub workspace_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum NotificationLevel {
    #[serde(rename = "info")]
    Info,
    #[serde(rename = "warning")]
    Warning,
    #[serde(rename = "error")]
    Error,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotificationMarker {
    pub level: NotificationLevel,
    pub notification: Id,
    pub unread: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotifyResult {
    pub notification: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Pane {
    LivePane(LivePane),
    DeadPane(DeadPane),
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PaneDirection {
    #[serde(rename = "left")]
    Left,
    #[serde(rename = "right")]
    Right,
    #[serde(rename = "up")]
    Up,
    #[serde(rename = "down")]
    Down,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaneNeighborResult {
    pub pane: Nullable<Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PingResult {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub build_commit: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub ghostty_commit: Optional<String>,
    pub ok: bool,
    pub protocol: u32,
    pub version: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProcessInfoResult {
    pub command: Nullable<String>,
    pub cwd: Nullable<String>,
    pub pid: Nullable<u32>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderWorkspaceMutationResult {
    pub key: String,
    pub workspace: Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadScreenResult {
    pub text: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadScrollbackResult {
    pub rows: Vec<RenderRow>,
    pub start: u32,
    pub total: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderCursor {
    pub blink: bool,
    pub color: Nullable<ColorHex>,
    pub style: CursorStyle,
    pub visible: bool,
    pub x: u16,
    pub y: u16,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderRow {
    pub row: u32,
    pub runs: Vec<RenderRun>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderRun {
    pub attrs: u32,
    pub bg: Nullable<ColorHex>,
    pub fg: Nullable<ColorHex>,
    pub text: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub underline: Option<RenderUnderline>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub width_hint: Option<u16>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RenderUnderline {
    #[serde(rename = "single")]
    Single,
    #[serde(rename = "double")]
    Double,
    #[serde(rename = "curly")]
    Curly,
    #[serde(rename = "dotted")]
    Dotted,
    #[serde(rename = "dashed")]
    Dashed,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReportAgentResult {
    pub session: Nullable<String>,
    pub source: AgentReportSource,
    pub state: AgentState,
    pub surface: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResizeSurfaceResult {
    pub accepted: bool,
    pub reservation_id: Nullable<u64>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResolveTerminalResult {
    pub exit: Nullable<JsonValue>,
    pub generation: String,
    pub launch_spec: JsonValue,
    pub lifecycle: TerminalLifecycle,
    pub registry_id: String,
    pub surface: Nullable<Id>,
    pub terminal_id: String,
    pub terminal_incarnation: Nullable<String>,
    pub terminal_revision: u64,
    pub workspace_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunResult {
    pub pane: Id,
    pub screen: Id,
    pub surface: Id,
    pub terminal_id: Nullable<String>,
    pub terminal_incarnation: Nullable<String>,
    pub workspace: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Screen {
    pub active: bool,
    pub active_pane: Id,
    pub id: Id,
    pub layout: Layout,
    pub name: Nullable<String>,
    pub panes: Vec<Pane>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub short_id: Option<String>,
    pub zoomed_pane: Nullable<Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetCellPixelsResult {
    pub failures: Vec<CellPixelFailure>,
    pub resizes: Vec<CellPixelResize>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShutdownDaemonResult {
    pub accepted: bool,
    pub generation: String,
    pub pid: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SidebarPluginResult {
    pub error: Nullable<String>,
    pub retry_after_ms: Nullable<u64>,
    pub surface: Nullable<Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SplitDirection {
    #[serde(rename = "right")]
    Right,
    #[serde(rename = "down")]
    Down,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceResult {
    pub surface: Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_incarnation: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TabBrowserSource {
    #[serde(rename = "external")]
    External,
    #[serde(rename = "launched")]
    Launched,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TabBrowserStatus {
    #[serde(rename = "starting")]
    Starting,
    #[serde(rename = "live")]
    Live,
    #[serde(rename = "failed")]
    Failed,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TabKind {
    #[serde(rename = "pty")]
    Pty,
    #[serde(rename = "browser")]
    Browser,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tab {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_error: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_frames_stalled: Optional<bool>,
    pub browser_source: Nullable<TabBrowserSource>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_status: Optional<TabBrowserStatus>,
    pub dead: bool,
    pub kind: TabKind,
    pub name: Nullable<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub notification: Optional<NotificationMarker>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub short_id: Option<String>,
    pub size: Nullable<Size>,
    pub surface: Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_incarnation: Optional<String>,
    pub title: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalColors {
    pub bg: Nullable<ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor: Optional<ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_blink: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_style: Optional<CursorStyle>,
    pub fg: Nullable<ColorHex>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub palette: Option<BTreeMap<String, ColorHex>>,
    pub selection_bg: Nullable<ColorHex>,
    pub selection_fg: Nullable<ColorHex>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalEventsResult {
    pub events: Vec<TerminalRegistryEvent>,
    pub generation: String,
    pub registry_id: String,
    pub terminal_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TerminalLifecycle {
    #[serde(rename = "launching")]
    Launching,
    #[serde(rename = "adopting")]
    Adopting,
    #[serde(rename = "running")]
    Running,
    #[serde(rename = "exited")]
    Exited,
    #[serde(rename = "tombstoned")]
    Tombstoned,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalPlacement {
    pub generation: String,
    pub key: String,
    pub lifecycle: Nullable<String>,
    pub pane: Id,
    pub registry_id: String,
    pub replayed: bool,
    pub screen: Id,
    pub surface: Id,
    pub terminal_id: Nullable<String>,
    pub terminal_incarnation: Nullable<String>,
    pub terminal_revision: u64,
    pub workspace: Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalRecord {
    pub exit: Nullable<JsonValue>,
    pub launch_spec: JsonValue,
    pub lifecycle: TerminalLifecycle,
    pub terminal_id: String,
    pub terminal_incarnation: Nullable<String>,
    pub workspace_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalRegistryEvent {
    pub kind: String,
    pub mutation_id: String,
    pub origin: String,
    pub result: JsonValue,
    pub terminal_id: String,
    pub terminal_revision: u64,
    pub workspace_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tree {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub generation: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub pane_revision: Option<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub registry_id: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub terminal_revision: Option<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub workspace_revision: Option<u64>,
    pub workspaces: Vec<Workspace>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VtStateResult {
    pub cols: u16,
    pub data: Base64,
    pub rows: u16,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaitForResult {
    pub elapsed_ms: u64,
    pub matched: bool,
    pub text: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub active: bool,
    pub id: Id,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    pub name: String,
    pub screens: Vec<Screen>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub short_id: Option<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceMutationResult {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub changed: Option<bool>,
    pub generation: String,
    pub index: u64,
    pub key: String,
    pub registry_id: String,
    pub replayed: bool,
    pub workspace: Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ZoomPaneResult {
    pub pane: Id,
    pub zoomed: bool,
    pub zoomed_pane: Nullable<Id>,
}

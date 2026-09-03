// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR 3abe68cfbb73abb8aab5265d34cdafd7207a111cbe9e1923c8637f5376abb929.
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
pub struct AttachedViewOutcomeResult {
    pub outcome: ViewAttachmentOutcome,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttachedViewResizeResult {
    pub accepted: bool,
    pub outcome: ViewAttachmentOutcome,
    pub reservation_id: Nullable<u64>,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserProviderAuthentication {
    #[serde(rename = "none")]
    None,
    #[serde(rename = "bearer")]
    Bearer,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserProviderSnapshot {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub authentication: Option<BrowserProviderAuthentication>,
    pub available: bool,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub clients: Option<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub provider_id: Option<String>,
    pub revision: u64,
    pub targets: Vec<BrowserProviderTarget>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserProviderTarget {
    pub tab_id: String,
    pub target_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserProviderUnregisterResult {
    pub removed: bool,
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
pub struct CellPixelSurface {
    pub height_px: u16,
    pub surface: Id,
    pub width_px: u16,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FrontendFocusTarget {
    #[serde(rename = "pane")]
    Pane,
    #[serde(rename = "machine_rail")]
    MachineRail,
    #[serde(rename = "workspace_rail")]
    WorkspaceRail,
    #[serde(rename = "tabs_rail")]
    TabsRail,
    #[serde(rename = "projection_rail")]
    ProjectionRail,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum FrontendJournalEvent {
    #[serde(rename = "focus")]
    Focus {
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        content_id: Optional<String>,
        event_id: String,
        frontend_projection_id: String,
        generation: String,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        pane_id: Optional<String>,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        screen_id: Optional<String>,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        tab_id: Optional<String>,
        target: FrontendFocusTarget,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        workspace_id: Optional<String>,
    },
    #[serde(rename = "resize")]
    Resize {
        cell_height: u16,
        cell_width: u16,
        cols: u16,
        event_id: String,
        frontend_projection_id: String,
        generation: String,
        rows: u16,
    },
    #[serde(rename = "viewport")]
    Viewport {
        event_id: String,
        frontend_projection_id: String,
        generation: String,
        offset: u64,
        #[serde(default, skip_serializing_if = "Optional::is_missing")]
        screen_id: Optional<String>,
        settled: bool,
        target: u64,
    },
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GetCellPixelsResult {
    pub height_px: u16,
    pub surfaces: Vec<CellPixelSurface>,
    pub width_px: u16,
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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub lifecycle_ready: Option<bool>,
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
pub struct KittyGraphicsState {
    pub alternate_next_image_id: u32,
    pub alternate_replay_next_image_id: u32,
    pub image_bytes: u64,
    pub images: u64,
    pub inflight_bytes: u64,
    pub placements: u64,
    pub primary_next_image_id: u32,
    pub primary_replay_next_image_id: u32,
    pub replay_cursor_offset: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KittyImageAlias {
    pub image_id: u32,
    pub image_number: u32,
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
pub struct LayoutUndoConfirmationRequired {
    pub closes_panes: Vec<Id>,
    pub confirmation_required: bool,
    pub revision: u64,
    pub screen: Id,
    pub undone: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LayoutUndoResult {
    LayoutUndoUndone(LayoutUndoUndone),
    LayoutUndoConfirmationRequired(LayoutUndoConfirmationRequired),
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutUndoUndone {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub confirmation_required: Option<bool>,
    pub revision: u64,
    pub screen: Id,
    pub undone: bool,
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
pub struct MachineUsage {
    pub api_equivalent_usd: f64,
    pub as_of: Nullable<String>,
    pub period_days: u32,
    pub total_tokens: u64,
    pub vm_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MachineUsageResult {
    pub usage: Nullable<MachineUsage>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MintTerminalRendererResult {
    pub endpoint: String,
    pub incarnation: String,
    pub protocol_version: u16,
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
    /// Working directory of the process group that owns the PTY, read at request time. Null when the lookup fails; absent from daemons that predate the field. Clients treat absence as null.
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub foreground_cwd: Optional<String>,
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
    pub epoch: u64,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RenderGraphicFormat {
    #[serde(rename = "rgb")]
    Rgb,
    #[serde(rename = "rgba")]
    Rgba,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderGraphicImage {
    pub data: Base64,
    pub format: RenderGraphicFormat,
    pub generation: u64,
    pub height: u32,
    pub id: u32,
    pub width: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderGraphicPlacement {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub anchor_col: Option<u16>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub anchor_row: Option<u32>,
    pub columns: u32,
    pub grid_cols: u32,
    pub grid_rows: u32,
    pub image_id: u32,
    pub ordinal: u32,
    pub pixel_height: u32,
    pub pixel_width: u32,
    pub placement_id: u32,
    pub rows: u32,
    pub source_height: u32,
    pub source_width: u32,
    pub source_x: u32,
    pub source_y: u32,
    pub viewport_col: i32,
    pub viewport_row: i32,
    pub viewport_visible: bool,
    pub x_offset: u32,
    pub y_offset: u32,
    pub z: i32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderGraphics {
    pub generation: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<RenderGraphicImage>>,
    pub placements: Vec<RenderGraphicPlacement>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub removed_image_ids: Option<Vec<u32>>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderGraphicsDelta {
    pub generation: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<RenderGraphicImage>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub placements: Option<Vec<RenderGraphicPlacement>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub removed_image_ids: Option<Vec<u32>>,
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
    pub exit: Nullable<TerminalExit>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ResourceSelectors {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub agent: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub client: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub frontend_projection: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub machine: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub notification: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pairing_request: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub screen: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub session: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub sidebar_view: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub split: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub stream: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub tab: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunResult {
    pub already_exited: bool,
    pub exit: Nullable<TerminalExit>,
    pub lifecycle: TerminalLifecycle,
    pub pane: Nullable<Id>,
    pub screen: Nullable<Id>,
    pub surface: Nullable<Id>,
    pub terminal_id: String,
    pub terminal_incarnation: Nullable<String>,
    pub terminal_revision: u64,
    pub workspace: Nullable<Id>,
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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub supports_clear_history_key_fallback: Option<bool>,
    pub surface: Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_incarnation: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_resource_id: Optional<String>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalExit {
    pub exited_at_ms: u64,
    pub outcome: TerminalExitOutcome,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum TerminalExitOutcome {
    #[serde(rename = "exit")]
    Exit {
        code: i32,
    },
    #[serde(rename = "signal")]
    Signal {
        core_dumped: bool,
        signal: i32,
    },
    #[serde(rename = "unknown")]
    Unknown {
        reason: String,
    },
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TerminalKey {
    #[serde(rename = "unidentified")]
    Unidentified,
    #[serde(rename = "backquote")]
    Backquote,
    #[serde(rename = "backslash")]
    Backslash,
    #[serde(rename = "bracket-left")]
    BracketLeft,
    #[serde(rename = "bracket-right")]
    BracketRight,
    #[serde(rename = "comma")]
    Comma,
    #[serde(rename = "digit0")]
    Digit0,
    #[serde(rename = "digit1")]
    Digit1,
    #[serde(rename = "digit2")]
    Digit2,
    #[serde(rename = "digit3")]
    Digit3,
    #[serde(rename = "digit4")]
    Digit4,
    #[serde(rename = "digit5")]
    Digit5,
    #[serde(rename = "digit6")]
    Digit6,
    #[serde(rename = "digit7")]
    Digit7,
    #[serde(rename = "digit8")]
    Digit8,
    #[serde(rename = "digit9")]
    Digit9,
    #[serde(rename = "equal")]
    Equal,
    #[serde(rename = "a")]
    A,
    #[serde(rename = "b")]
    B,
    #[serde(rename = "c")]
    C,
    #[serde(rename = "d")]
    D,
    #[serde(rename = "e")]
    E,
    #[serde(rename = "f")]
    F,
    #[serde(rename = "g")]
    G,
    #[serde(rename = "h")]
    H,
    #[serde(rename = "i")]
    I,
    #[serde(rename = "j")]
    J,
    #[serde(rename = "k")]
    K,
    #[serde(rename = "l")]
    L,
    #[serde(rename = "m")]
    M,
    #[serde(rename = "n")]
    N,
    #[serde(rename = "o")]
    O,
    #[serde(rename = "p")]
    P,
    #[serde(rename = "q")]
    Q,
    #[serde(rename = "r")]
    R,
    #[serde(rename = "s")]
    S,
    #[serde(rename = "t")]
    T,
    #[serde(rename = "u")]
    U,
    #[serde(rename = "v")]
    V,
    #[serde(rename = "w")]
    W,
    #[serde(rename = "x")]
    X,
    #[serde(rename = "y")]
    Y,
    #[serde(rename = "z")]
    Z,
    #[serde(rename = "minus")]
    Minus,
    #[serde(rename = "period")]
    Period,
    #[serde(rename = "quote")]
    Quote,
    #[serde(rename = "semicolon")]
    Semicolon,
    #[serde(rename = "slash")]
    Slash,
    #[serde(rename = "backspace")]
    Backspace,
    #[serde(rename = "enter")]
    Enter,
    #[serde(rename = "space")]
    Space,
    #[serde(rename = "tab")]
    Tab,
    #[serde(rename = "delete")]
    Delete,
    #[serde(rename = "end")]
    End,
    #[serde(rename = "home")]
    Home,
    #[serde(rename = "insert")]
    Insert,
    #[serde(rename = "page-down")]
    PageDown,
    #[serde(rename = "page-up")]
    PageUp,
    #[serde(rename = "arrow-down")]
    ArrowDown,
    #[serde(rename = "arrow-left")]
    ArrowLeft,
    #[serde(rename = "arrow-right")]
    ArrowRight,
    #[serde(rename = "arrow-up")]
    ArrowUp,
    #[serde(rename = "numpad0")]
    Numpad0,
    #[serde(rename = "numpad1")]
    Numpad1,
    #[serde(rename = "numpad2")]
    Numpad2,
    #[serde(rename = "numpad3")]
    Numpad3,
    #[serde(rename = "numpad4")]
    Numpad4,
    #[serde(rename = "numpad5")]
    Numpad5,
    #[serde(rename = "numpad6")]
    Numpad6,
    #[serde(rename = "numpad7")]
    Numpad7,
    #[serde(rename = "numpad8")]
    Numpad8,
    #[serde(rename = "numpad9")]
    Numpad9,
    #[serde(rename = "numpad-add")]
    NumpadAdd,
    #[serde(rename = "numpad-backspace")]
    NumpadBackspace,
    #[serde(rename = "numpad-comma")]
    NumpadComma,
    #[serde(rename = "numpad-decimal")]
    NumpadDecimal,
    #[serde(rename = "numpad-divide")]
    NumpadDivide,
    #[serde(rename = "numpad-enter")]
    NumpadEnter,
    #[serde(rename = "numpad-equal")]
    NumpadEqual,
    #[serde(rename = "numpad-multiply")]
    NumpadMultiply,
    #[serde(rename = "numpad-subtract")]
    NumpadSubtract,
    #[serde(rename = "numpad-up")]
    NumpadUp,
    #[serde(rename = "numpad-down")]
    NumpadDown,
    #[serde(rename = "numpad-right")]
    NumpadRight,
    #[serde(rename = "numpad-left")]
    NumpadLeft,
    #[serde(rename = "numpad-begin")]
    NumpadBegin,
    #[serde(rename = "numpad-home")]
    NumpadHome,
    #[serde(rename = "numpad-end")]
    NumpadEnd,
    #[serde(rename = "numpad-insert")]
    NumpadInsert,
    #[serde(rename = "numpad-delete")]
    NumpadDelete,
    #[serde(rename = "numpad-page-up")]
    NumpadPageUp,
    #[serde(rename = "numpad-page-down")]
    NumpadPageDown,
    #[serde(rename = "escape")]
    Escape,
    #[serde(rename = "f1")]
    F1,
    #[serde(rename = "f2")]
    F2,
    #[serde(rename = "f3")]
    F3,
    #[serde(rename = "f4")]
    F4,
    #[serde(rename = "f5")]
    F5,
    #[serde(rename = "f6")]
    F6,
    #[serde(rename = "f7")]
    F7,
    #[serde(rename = "f8")]
    F8,
    #[serde(rename = "f9")]
    F9,
    #[serde(rename = "f10")]
    F10,
    #[serde(rename = "f11")]
    F11,
    #[serde(rename = "f12")]
    F12,
    #[serde(rename = "f13")]
    F13,
    #[serde(rename = "f14")]
    F14,
    #[serde(rename = "f15")]
    F15,
    #[serde(rename = "f16")]
    F16,
    #[serde(rename = "f17")]
    F17,
    #[serde(rename = "f18")]
    F18,
    #[serde(rename = "f19")]
    F19,
    #[serde(rename = "f20")]
    F20,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TerminalKeyAction {
    #[serde(rename = "press")]
    Press,
    #[serde(rename = "release")]
    Release,
    #[serde(rename = "repeat")]
    Repeat,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalKeyInput {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub action: Optional<TerminalKeyAction>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub base_layout_codepoint: Optional<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub composing: Option<bool>,
    pub consumed_mods: TerminalModifiers,
    pub key: TerminalKey,
    pub macos_option_as_alt: bool,
    pub mods: TerminalModifiers,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub shifted_codepoint: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub unshifted_codepoint: Optional<String>,
    pub utf8: String,
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
pub struct TerminalModifiers {
    pub alt: bool,
    pub caps_lock: bool,
    pub control: bool,
    pub num_lock: bool,
    pub shift: bool,
    #[serde(rename = "super")]
    pub super_: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalPlacement {
    pub already_exited: bool,
    pub exit: Nullable<TerminalExit>,
    pub generation: String,
    pub key: String,
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
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalRecord {
    pub exit: Nullable<TerminalExit>,
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ViewAttachmentOutcome {
    #[serde(rename = "applied")]
    Applied,
    #[serde(rename = "passive")]
    Passive,
    #[serde(rename = "superseded")]
    Superseded,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VtStateResult {
    pub cols: u16,
    pub data: Base64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_graphics_state: Option<KittyGraphicsState>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_image_aliases: Option<Vec<KittyImageAlias>>,
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

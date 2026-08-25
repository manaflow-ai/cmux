// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR 65aa592727bc414fe3e66ac125c9b8541a1926bbe9eaa572acc66b4681bf6589.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use super::metadata::*;
use super::types as T;
use crate::{EventMetadata, Nullable, Optional};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentChangedEvent {
    pub session: Nullable<String>,
    pub source: T::AgentSource,
    pub state: T::AgentState,
    pub surface: T::Id,
    pub updated_at_ms: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BellEvent {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserStateEventStatus {
    #[serde(rename = "starting")]
    Starting,
    #[serde(rename = "live")]
    Live,
    #[serde(rename = "failed")]
    Failed,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserStateEvent {
    pub cols: u16,
    pub error: Nullable<String>,
    /// The initial browser-state includes the latest frame when one exists; later state updates omit it.
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub frame: Optional<T::BrowserFrame>,
    pub frames_stalled: bool,
    pub rows: u16,
    pub status: BrowserStateEventStatus,
    pub surface: T::Id,
    pub title: String,
    pub url: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClientAttachedEventTransport {
    #[serde(rename = "unix")]
    Unix,
    #[serde(rename = "ws")]
    Ws,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientAttachedEvent {
    pub client: u64,
    pub kind: Nullable<String>,
    pub name: Nullable<String>,
    pub transport: ClientAttachedEventTransport,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientChangedEvent {
    pub client: u64,
    pub kind: Nullable<String>,
    pub name: Nullable<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientDetachedEvent {
    pub client: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ClientListInvalidatedEvent {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ColorsChangedEvent {
    pub bg: Nullable<T::ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor: Optional<T::ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_blink: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_style: Optional<T::CursorStyle>,
    pub fg: Nullable<T::ColorHex>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub palette: Option<BTreeMap<String, T::ColorHex>>,
    pub selection_bg: Nullable<T::ColorHex>,
    pub selection_fg: Nullable<T::ColorHex>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub surface: Option<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ConfigReloadRequestedEvent {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetachedEvent {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct EmptyEvent {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrameEvent {
    pub data: T::Base64,
    pub height: u32,
    pub seq: u64,
    pub surface: T::Id,
    pub width: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrontendProjectionChangedEvent {
    pub frontend: String,
    pub mutation_id: String,
    pub origin: String,
    pub projection_revision: u64,
    pub scope: String,
    pub subject_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum GraphicsStatusEventKind {
    #[serde(rename = "kitty-image-budget-worker-start-failed")]
    KittyImageBudgetWorkerStartFailed,
    #[serde(rename = "kitty-image-budget-update-failed")]
    KittyImageBudgetUpdateFailed,
    #[serde(rename = "cell-pixel-update-retries-exhausted")]
    CellPixelUpdateRetriesExhausted,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GraphicsStatusEvent {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub attempts: Option<u16>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub cell_height: Option<u16>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub cell_width: Option<u16>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub kind: GraphicsStatusEventKind,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub remaining: Option<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub retry_exhausted: Option<bool>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutChangedEvent {
    pub screen: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotificationEvent {
    pub body: String,
    pub level: T::NotificationLevel,
    pub notification: T::Id,
    pub surface: Nullable<T::Id>,
    pub title: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OutputEvent {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub colors: Option<T::TerminalColors>,
    pub data: T::Base64,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OverflowEvent {
    pub error: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub surface: Option<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PairingRequestedEvent {
    pub code: String,
    pub expires_in: u64,
    pub peer: String,
    pub request: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PairingResolvedEvent {
    pub request: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaneAddedEvent {
    pub entity: T::Pane,
    pub index: u64,
    pub pane: T::Id,
    pub screen: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaneClosedEvent {
    pub entity: T::Pane,
    pub index: u64,
    pub pane: T::Id,
    pub screen: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderDeltaEvent {
    pub cursor: T::RenderCursor,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub default_bg: Option<T::ColorHex>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub default_fg: Option<T::ColorHex>,
    pub full: bool,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub graphics: Option<T::RenderGraphicsDelta>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub history_epoch: Option<u64>,
    pub rows: Vec<T::RenderRow>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub scrollback_rows: Option<u32>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub size: Option<T::Size>,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenderStateEvent {
    pub cursor: T::RenderCursor,
    pub default_bg: T::ColorHex,
    pub default_fg: T::ColorHex,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub graphics: Option<T::RenderGraphics>,
    pub history_epoch: u64,
    pub rows: Vec<T::RenderRow>,
    pub scrollback_rows: u32,
    pub size: T::Size,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResizedEvent {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub colors: Option<T::TerminalColors>,
    pub cols: u16,
    /// Protocol 6 compatibility field.
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub data: Option<T::Base64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_graphics_state: Option<T::KittyGraphicsState>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_image_aliases: Option<Vec<T::KittyImageAlias>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub replay: Option<T::Base64>,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScreenAddedEvent {
    pub entity: T::Screen,
    pub index: u64,
    pub screen: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScreenClosedEvent {
    pub entity: T::Screen,
    pub index: u64,
    pub screen: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScreenRenamedEvent {
    pub entity: T::Screen,
    pub screen: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScrollChangedEvent {
    pub at_bottom: bool,
    pub offset: u64,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StatusEvent {
    pub message: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceExitedEvent {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceOutputEvent {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceResizeFailedEvent {
    pub cols: u16,
    pub error: String,
    pub reservation_id: Nullable<u64>,
    pub retry_after_ms: Nullable<u64>,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceResizedEvent {
    pub cols: u16,
    pub reservation_id: Nullable<u64>,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabAddedEvent {
    pub entity: T::Tab,
    pub index: u64,
    pub pane: T::Id,
    pub screen: T::Id,
    pub surface: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabClosedEvent {
    pub entity: T::Tab,
    pub index: u64,
    pub pane: T::Id,
    pub screen: T::Id,
    pub surface: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TabRenamedEvent {
    pub entity: T::Tab,
    pub pane: T::Id,
    pub screen: T::Id,
    pub surface: T::Id,
    pub workspace: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TerminalRegistryChangedEvent {
    pub generation: String,
    pub refetch: String,
    pub registry_id: String,
    pub terminal_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TitleChangedEvent {
    pub surface: T::Id,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct TreeChangedEvent {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VtStateEvent {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub colors: Option<T::TerminalColors>,
    pub cols: u16,
    pub data: T::Base64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_graphics_state: Option<T::KittyGraphicsState>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub kitty_image_aliases: Option<Vec<T::KittyImageAlias>>,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WindowTitleRequestedEvent {
    pub title: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceAddedEvent {
    pub entity: T::Workspace,
    pub generation: String,
    pub index: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub mutation_id: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub registry_id: String,
    pub workspace: T::Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceClosedEvent {
    pub entity: T::Workspace,
    pub generation: String,
    pub index: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub mutation_id: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub registry_id: String,
    pub workspace: T::Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceMovedEvent {
    pub entity: T::Workspace,
    pub generation: String,
    pub index: u64,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub mutation_id: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub registry_id: String,
    pub workspace: T::Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorkspaceRenamedEvent {
    pub entity: T::Workspace,
    pub generation: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub mutation_id: Option<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    pub registry_id: String,
    pub workspace: T::Id,
    pub workspace_revision: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq)]
pub struct UnknownEvent {
    pub name: Option<String>,
    pub raw: Value,
    pub decode_error: Option<String>,
}

#[rustfmt::skip]
#[non_exhaustive]
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    AgentChanged(AgentChangedEvent),
    Bell(BellEvent),
    BrowserState(BrowserStateEvent),
    ClientAttached(ClientAttachedEvent),
    ClientChanged(ClientChangedEvent),
    ClientDetached(ClientDetachedEvent),
    ClientListInvalidated(ClientListInvalidatedEvent),
    ColorsChanged(ColorsChangedEvent),
    ConfigReloadRequested(ConfigReloadRequestedEvent),
    Detached(DetachedEvent),
    Empty(EmptyEvent),
    Frame(FrameEvent),
    FrontendProjectionChanged(FrontendProjectionChangedEvent),
    GraphicsStatus(GraphicsStatusEvent),
    LayoutChanged(LayoutChangedEvent),
    Notification(NotificationEvent),
    Output(OutputEvent),
    Overflow(OverflowEvent),
    PairingRequested(PairingRequestedEvent),
    PairingResolved(PairingResolvedEvent),
    PaneAdded(PaneAddedEvent),
    PaneClosed(PaneClosedEvent),
    RenderDelta(RenderDeltaEvent),
    RenderState(RenderStateEvent),
    Resized(ResizedEvent),
    ScreenAdded(ScreenAddedEvent),
    ScreenClosed(ScreenClosedEvent),
    ScreenRenamed(ScreenRenamedEvent),
    ScrollChanged(ScrollChangedEvent),
    Status(StatusEvent),
    SurfaceExited(SurfaceExitedEvent),
    SurfaceOutput(SurfaceOutputEvent),
    SurfaceResizeFailed(SurfaceResizeFailedEvent),
    SurfaceResized(SurfaceResizedEvent),
    TabAdded(TabAddedEvent),
    TabClosed(TabClosedEvent),
    TabRenamed(TabRenamedEvent),
    TerminalRegistryChanged(TerminalRegistryChangedEvent),
    TitleChanged(TitleChangedEvent),
    TreeChanged(TreeChangedEvent),
    VtState(VtStateEvent),
    WindowTitleRequested(WindowTitleRequestedEvent),
    WorkspaceAdded(WorkspaceAddedEvent),
    WorkspaceClosed(WorkspaceClosedEvent),
    WorkspaceMoved(WorkspaceMovedEvent),
    WorkspaceRenamed(WorkspaceRenamedEvent),
    Unknown(UnknownEvent),
}

#[rustfmt::skip]
impl Event {
    pub fn wire_name(&self) -> Option<&str> {
        match self {
            Self::AgentChanged(_) => Some("agent-changed"),
            Self::Bell(_) => Some("bell"),
            Self::BrowserState(_) => Some("browser-state"),
            Self::ClientAttached(_) => Some("client-attached"),
            Self::ClientChanged(_) => Some("client-changed"),
            Self::ClientDetached(_) => Some("client-detached"),
            Self::ClientListInvalidated(_) => Some("client-list-invalidated"),
            Self::ColorsChanged(_) => Some("colors-changed"),
            Self::ConfigReloadRequested(_) => Some("config-reload-requested"),
            Self::Detached(_) => Some("detached"),
            Self::Empty(_) => Some("empty"),
            Self::Frame(_) => Some("frame"),
            Self::FrontendProjectionChanged(_) => Some("frontend-projection-changed"),
            Self::GraphicsStatus(_) => Some("graphics-status"),
            Self::LayoutChanged(_) => Some("layout-changed"),
            Self::Notification(_) => Some("notification"),
            Self::Output(_) => Some("output"),
            Self::Overflow(_) => Some("overflow"),
            Self::PairingRequested(_) => Some("pairing-requested"),
            Self::PairingResolved(_) => Some("pairing-resolved"),
            Self::PaneAdded(_) => Some("pane-added"),
            Self::PaneClosed(_) => Some("pane-closed"),
            Self::RenderDelta(_) => Some("render-delta"),
            Self::RenderState(_) => Some("render-state"),
            Self::Resized(_) => Some("resized"),
            Self::ScreenAdded(_) => Some("screen-added"),
            Self::ScreenClosed(_) => Some("screen-closed"),
            Self::ScreenRenamed(_) => Some("screen-renamed"),
            Self::ScrollChanged(_) => Some("scroll-changed"),
            Self::Status(_) => Some("status"),
            Self::SurfaceExited(_) => Some("surface-exited"),
            Self::SurfaceOutput(_) => Some("surface-output"),
            Self::SurfaceResizeFailed(_) => Some("surface-resize-failed"),
            Self::SurfaceResized(_) => Some("surface-resized"),
            Self::TabAdded(_) => Some("tab-added"),
            Self::TabClosed(_) => Some("tab-closed"),
            Self::TabRenamed(_) => Some("tab-renamed"),
            Self::TerminalRegistryChanged(_) => Some("terminal-registry-changed"),
            Self::TitleChanged(_) => Some("title-changed"),
            Self::TreeChanged(_) => Some("tree-changed"),
            Self::VtState(_) => Some("vt-state"),
            Self::WindowTitleRequested(_) => Some("window-title-requested"),
            Self::WorkspaceAdded(_) => Some("workspace-added"),
            Self::WorkspaceClosed(_) => Some("workspace-closed"),
            Self::WorkspaceMoved(_) => Some("workspace-moved"),
            Self::WorkspaceRenamed(_) => Some("workspace-renamed"),
            Self::Unknown(event) => event.name.as_deref(),
        }
    }

    pub fn metadata(&self) -> Option<&'static EventMetadata> {
        match self {
            Self::AgentChanged(_) => Some(&AGENT_CHANGED_EVENT_METADATA),
            Self::Bell(_) => Some(&BELL_EVENT_METADATA),
            Self::BrowserState(_) => Some(&BROWSER_STATE_EVENT_METADATA),
            Self::ClientAttached(_) => Some(&CLIENT_ATTACHED_EVENT_METADATA),
            Self::ClientChanged(_) => Some(&CLIENT_CHANGED_EVENT_METADATA),
            Self::ClientDetached(_) => Some(&CLIENT_DETACHED_EVENT_METADATA),
            Self::ClientListInvalidated(_) => Some(&CLIENT_LIST_INVALIDATED_EVENT_METADATA),
            Self::ColorsChanged(_) => Some(&COLORS_CHANGED_EVENT_METADATA),
            Self::ConfigReloadRequested(_) => Some(&CONFIG_RELOAD_REQUESTED_EVENT_METADATA),
            Self::Detached(_) => Some(&DETACHED_EVENT_METADATA),
            Self::Empty(_) => Some(&EMPTY_EVENT_METADATA),
            Self::Frame(_) => Some(&FRAME_EVENT_METADATA),
            Self::FrontendProjectionChanged(_) => Some(&FRONTEND_PROJECTION_CHANGED_EVENT_METADATA),
            Self::GraphicsStatus(_) => Some(&GRAPHICS_STATUS_EVENT_METADATA),
            Self::LayoutChanged(_) => Some(&LAYOUT_CHANGED_EVENT_METADATA),
            Self::Notification(_) => Some(&NOTIFICATION_EVENT_METADATA),
            Self::Output(_) => Some(&OUTPUT_EVENT_METADATA),
            Self::Overflow(_) => Some(&OVERFLOW_EVENT_METADATA),
            Self::PairingRequested(_) => Some(&PAIRING_REQUESTED_EVENT_METADATA),
            Self::PairingResolved(_) => Some(&PAIRING_RESOLVED_EVENT_METADATA),
            Self::PaneAdded(_) => Some(&PANE_ADDED_EVENT_METADATA),
            Self::PaneClosed(_) => Some(&PANE_CLOSED_EVENT_METADATA),
            Self::RenderDelta(_) => Some(&RENDER_DELTA_EVENT_METADATA),
            Self::RenderState(_) => Some(&RENDER_STATE_EVENT_METADATA),
            Self::Resized(_) => Some(&RESIZED_EVENT_METADATA),
            Self::ScreenAdded(_) => Some(&SCREEN_ADDED_EVENT_METADATA),
            Self::ScreenClosed(_) => Some(&SCREEN_CLOSED_EVENT_METADATA),
            Self::ScreenRenamed(_) => Some(&SCREEN_RENAMED_EVENT_METADATA),
            Self::ScrollChanged(_) => Some(&SCROLL_CHANGED_EVENT_METADATA),
            Self::Status(_) => Some(&STATUS_EVENT_METADATA),
            Self::SurfaceExited(_) => Some(&SURFACE_EXITED_EVENT_METADATA),
            Self::SurfaceOutput(_) => Some(&SURFACE_OUTPUT_EVENT_METADATA),
            Self::SurfaceResizeFailed(_) => Some(&SURFACE_RESIZE_FAILED_EVENT_METADATA),
            Self::SurfaceResized(_) => Some(&SURFACE_RESIZED_EVENT_METADATA),
            Self::TabAdded(_) => Some(&TAB_ADDED_EVENT_METADATA),
            Self::TabClosed(_) => Some(&TAB_CLOSED_EVENT_METADATA),
            Self::TabRenamed(_) => Some(&TAB_RENAMED_EVENT_METADATA),
            Self::TerminalRegistryChanged(_) => Some(&TERMINAL_REGISTRY_CHANGED_EVENT_METADATA),
            Self::TitleChanged(_) => Some(&TITLE_CHANGED_EVENT_METADATA),
            Self::TreeChanged(_) => Some(&TREE_CHANGED_EVENT_METADATA),
            Self::VtState(_) => Some(&VT_STATE_EVENT_METADATA),
            Self::WindowTitleRequested(_) => Some(&WINDOW_TITLE_REQUESTED_EVENT_METADATA),
            Self::WorkspaceAdded(_) => Some(&WORKSPACE_ADDED_EVENT_METADATA),
            Self::WorkspaceClosed(_) => Some(&WORKSPACE_CLOSED_EVENT_METADATA),
            Self::WorkspaceMoved(_) => Some(&WORKSPACE_MOVED_EVENT_METADATA),
            Self::WorkspaceRenamed(_) => Some(&WORKSPACE_RENAMED_EVENT_METADATA),
            Self::Unknown(_) => None,
        }
    }
}

#[rustfmt::skip]
pub fn decode_event(raw: Value) -> Event {
    let name = raw.get("event").and_then(Value::as_str).map(str::to_owned);
    match name.as_deref() {
        Some("agent-changed") => match serde_json::from_value::<AgentChangedEvent>(raw.clone()) {
            Ok(event) => Event::AgentChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("bell") => match serde_json::from_value::<BellEvent>(raw.clone()) {
            Ok(event) => Event::Bell(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("browser-state") => match serde_json::from_value::<BrowserStateEvent>(raw.clone()) {
            Ok(event) => Event::BrowserState(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("client-attached") => match serde_json::from_value::<ClientAttachedEvent>(raw.clone()) {
            Ok(event) => Event::ClientAttached(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("client-changed") => match serde_json::from_value::<ClientChangedEvent>(raw.clone()) {
            Ok(event) => Event::ClientChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("client-detached") => match serde_json::from_value::<ClientDetachedEvent>(raw.clone()) {
            Ok(event) => Event::ClientDetached(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("client-list-invalidated") => match serde_json::from_value::<ClientListInvalidatedEvent>(raw.clone()) {
            Ok(event) => Event::ClientListInvalidated(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("colors-changed") => match serde_json::from_value::<ColorsChangedEvent>(raw.clone()) {
            Ok(event) => Event::ColorsChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("config-reload-requested") => match serde_json::from_value::<ConfigReloadRequestedEvent>(raw.clone()) {
            Ok(event) => Event::ConfigReloadRequested(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("detached") => match serde_json::from_value::<DetachedEvent>(raw.clone()) {
            Ok(event) => Event::Detached(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("empty") => match serde_json::from_value::<EmptyEvent>(raw.clone()) {
            Ok(event) => Event::Empty(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("frame") => match serde_json::from_value::<FrameEvent>(raw.clone()) {
            Ok(event) => Event::Frame(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("frontend-projection-changed") => match serde_json::from_value::<FrontendProjectionChangedEvent>(raw.clone()) {
            Ok(event) => Event::FrontendProjectionChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("graphics-status") => match serde_json::from_value::<GraphicsStatusEvent>(raw.clone()) {
            Ok(event) => Event::GraphicsStatus(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("layout-changed") => match serde_json::from_value::<LayoutChangedEvent>(raw.clone()) {
            Ok(event) => Event::LayoutChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("notification") => match serde_json::from_value::<NotificationEvent>(raw.clone()) {
            Ok(event) => Event::Notification(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("output") => match serde_json::from_value::<OutputEvent>(raw.clone()) {
            Ok(event) => Event::Output(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("overflow") => match serde_json::from_value::<OverflowEvent>(raw.clone()) {
            Ok(event) => Event::Overflow(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("pairing-requested") => match serde_json::from_value::<PairingRequestedEvent>(raw.clone()) {
            Ok(event) => Event::PairingRequested(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("pairing-resolved") => match serde_json::from_value::<PairingResolvedEvent>(raw.clone()) {
            Ok(event) => Event::PairingResolved(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("pane-added") => match serde_json::from_value::<PaneAddedEvent>(raw.clone()) {
            Ok(event) => Event::PaneAdded(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("pane-closed") => match serde_json::from_value::<PaneClosedEvent>(raw.clone()) {
            Ok(event) => Event::PaneClosed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("render-delta") => match serde_json::from_value::<RenderDeltaEvent>(raw.clone()) {
            Ok(event) => Event::RenderDelta(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("render-state") => match serde_json::from_value::<RenderStateEvent>(raw.clone()) {
            Ok(event) => Event::RenderState(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("resized") => match serde_json::from_value::<ResizedEvent>(raw.clone()) {
            Ok(event) => Event::Resized(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("screen-added") => match serde_json::from_value::<ScreenAddedEvent>(raw.clone()) {
            Ok(event) => Event::ScreenAdded(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("screen-closed") => match serde_json::from_value::<ScreenClosedEvent>(raw.clone()) {
            Ok(event) => Event::ScreenClosed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("screen-renamed") => match serde_json::from_value::<ScreenRenamedEvent>(raw.clone()) {
            Ok(event) => Event::ScreenRenamed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("scroll-changed") => match serde_json::from_value::<ScrollChangedEvent>(raw.clone()) {
            Ok(event) => Event::ScrollChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("status") => match serde_json::from_value::<StatusEvent>(raw.clone()) {
            Ok(event) => Event::Status(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("surface-exited") => match serde_json::from_value::<SurfaceExitedEvent>(raw.clone()) {
            Ok(event) => Event::SurfaceExited(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("surface-output") => match serde_json::from_value::<SurfaceOutputEvent>(raw.clone()) {
            Ok(event) => Event::SurfaceOutput(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("surface-resize-failed") => match serde_json::from_value::<SurfaceResizeFailedEvent>(raw.clone()) {
            Ok(event) => Event::SurfaceResizeFailed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("surface-resized") => match serde_json::from_value::<SurfaceResizedEvent>(raw.clone()) {
            Ok(event) => Event::SurfaceResized(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("tab-added") => match serde_json::from_value::<TabAddedEvent>(raw.clone()) {
            Ok(event) => Event::TabAdded(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("tab-closed") => match serde_json::from_value::<TabClosedEvent>(raw.clone()) {
            Ok(event) => Event::TabClosed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("tab-renamed") => match serde_json::from_value::<TabRenamedEvent>(raw.clone()) {
            Ok(event) => Event::TabRenamed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("terminal-registry-changed") => match serde_json::from_value::<TerminalRegistryChangedEvent>(raw.clone()) {
            Ok(event) => Event::TerminalRegistryChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("title-changed") => match serde_json::from_value::<TitleChangedEvent>(raw.clone()) {
            Ok(event) => Event::TitleChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("tree-changed") => match serde_json::from_value::<TreeChangedEvent>(raw.clone()) {
            Ok(event) => Event::TreeChanged(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("vt-state") => match serde_json::from_value::<VtStateEvent>(raw.clone()) {
            Ok(event) => Event::VtState(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("window-title-requested") => match serde_json::from_value::<WindowTitleRequestedEvent>(raw.clone()) {
            Ok(event) => Event::WindowTitleRequested(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("workspace-added") => match serde_json::from_value::<WorkspaceAddedEvent>(raw.clone()) {
            Ok(event) => Event::WorkspaceAdded(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("workspace-closed") => match serde_json::from_value::<WorkspaceClosedEvent>(raw.clone()) {
            Ok(event) => Event::WorkspaceClosed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("workspace-moved") => match serde_json::from_value::<WorkspaceMovedEvent>(raw.clone()) {
            Ok(event) => Event::WorkspaceMoved(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        Some("workspace-renamed") => match serde_json::from_value::<WorkspaceRenamedEvent>(raw.clone()) {
            Ok(event) => Event::WorkspaceRenamed(event),
            Err(error) => Event::Unknown(UnknownEvent {
                name,
                raw,
                decode_error: Some(error.to_string()),
            }),
        },
        _ => Event::Unknown(UnknownEvent {
            name,
            raw,
            decode_error: None,
        }),
    }
}

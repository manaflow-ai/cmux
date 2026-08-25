// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR b4e69e774777172ac0198454e7f068e53f7a74501dc787b58f3ead05d17b4af6.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use super::metadata::*;
use super::types as T;
use crate::{CmuxClient, CmuxStream, Nullable, Optional, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApplyLayoutRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    pub layout: T::DeclarativeLayout,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AttachSurfaceRequestMode {
    #[serde(rename = "bytes")]
    Bytes,
    #[serde(rename = "render")]
    Render,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AttachSurfaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mode: Optional<AttachSurfaceRequestMode>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type AttachSurfaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserActivateRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type BrowserActivateResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserBackRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type BrowserBackResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserForwardRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type BrowserForwardResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserFramePresentedRequest {
    pub frame_seq: u64,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type BrowserFramePresentedResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserInsertTextRequest {
    pub surface: T::Id,
    pub text: String,
}

#[rustfmt::skip]
pub type BrowserInsertTextResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserKeyRequestKind {
    #[serde(rename = "down")]
    Down,
    #[serde(rename = "up")]
    Up,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserKeyRequest {
    pub code: String,
    pub key: String,
    pub kind: BrowserKeyRequestKind,
    pub modifiers: u32,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub text: Optional<String>,
    pub windows_virtual_key_code: u32,
}

#[rustfmt::skip]
pub type BrowserKeyResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserKeyPressRequest {
    pub code: String,
    pub key: String,
    pub modifiers: u32,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub text: Optional<String>,
    pub windows_virtual_key_code: u32,
}

#[rustfmt::skip]
pub type BrowserKeyPressResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserMouseRequestKind {
    #[serde(rename = "down")]
    Down,
    #[serde(rename = "up")]
    Up,
    #[serde(rename = "move")]
    Move,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserMouseRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub button: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub click_count: Optional<u32>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub frame_seq: Optional<u64>,
    pub kind: BrowserMouseRequestKind,
    pub surface: T::Id,
    pub x_px: f64,
    pub y_px: f64,
}

#[rustfmt::skip]
pub type BrowserMouseResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BrowserMouseGuardedRequestKind {
    #[serde(rename = "down")]
    Down,
    #[serde(rename = "up")]
    Up,
    #[serde(rename = "move")]
    Move,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserMouseGuardedRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub button: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub click_count: Optional<u32>,
    pub frame_seq: u64,
    pub kind: BrowserMouseGuardedRequestKind,
    pub surface: T::Id,
    pub x_px: f64,
    pub y_px: f64,
}

#[rustfmt::skip]
pub type BrowserMouseGuardedResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserNavigateRequest {
    pub surface: T::Id,
    pub url: String,
}

#[rustfmt::skip]
pub type BrowserNavigateResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserReloadRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type BrowserReloadResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserWheelRequest {
    pub delta_y_px: f64,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub frame_seq: Optional<u64>,
    pub surface: T::Id,
    pub x_px: f64,
    pub y_px: f64,
}

#[rustfmt::skip]
pub type BrowserWheelResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserWheelGuardedRequest {
    pub delta_y_px: f64,
    pub frame_seq: u64,
    pub surface: T::Id,
    pub x_px: f64,
    pub y_px: f64,
}

#[rustfmt::skip]
pub type BrowserWheelGuardedResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClearHistoryRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub fallback_key: Optional<T::TerminalKeyInput>,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type ClearHistoryResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ClearWindowTitleRequest {
}

#[rustfmt::skip]
pub type ClearWindowTitleResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientFocusRequest {
    pub client_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientFocusResult {
    pub pane: Nullable<T::Id>,
    pub tab: Nullable<u64>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClosePaneRequest {
    pub pane: T::Id,
}

#[rustfmt::skip]
pub type ClosePaneResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseProviderManagedWorkspaceRequest {
    pub authority: String,
    pub key: String,
    pub workspace: T::Id,
}

#[rustfmt::skip]
pub type CloseProviderManagedWorkspaceResult = T::ProviderWorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseScreenRequest {
    pub screen: T::Id,
}

#[rustfmt::skip]
pub type CloseScreenResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseSurfaceRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type CloseSurfaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseTerminalRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub terminal_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_incarnation: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct CloseWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type CloseWorkspaceResult = T::WorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CopyRequestMode {
    #[serde(rename = "screen")]
    Screen,
    #[serde(rename = "selection")]
    Selection,
    #[serde(rename = "scrollback")]
    Scrollback,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CopyRequest {
    pub mode: CopyRequestMode,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateSurfaceWithReceiptRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub argv: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub idempotency_key: Optional<String>,
    pub operation: String,
    pub origin: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    pub receipt: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub selector_fallbacks: Option<Vec<T::ResourceSelectors>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub selectors: Optional<T::ResourceSelectors>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub url: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub width: Optional<f32>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type CreateSurfaceWithReceiptResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct CreateTerminalRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub argv: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub command: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type CreateTerminalResult = T::TerminalPlacement;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct CreateWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
}

#[rustfmt::skip]
pub type CreateWorkspaceResult = T::WorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetachAttachedViewRequest {
    pub lease: String,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type DetachAttachedViewResult = T::AttachedViewOutcomeResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetachClientRequest {
    pub client: u64,
}

#[rustfmt::skip]
pub type DetachClientResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ExportLayoutRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub screen: Optional<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusDirectionRequest {
    pub dir: T::PaneDirection,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusPaneRequest {
    pub pane: T::Id,
}

#[rustfmt::skip]
pub type FocusPaneResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct GetBrowserProviderRequest {
}

#[rustfmt::skip]
pub type GetBrowserProviderResult = T::BrowserProviderSnapshot;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct GetCellPixelsRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GetFrontendProjectionRequest {
    pub frontend: String,
    pub scope: String,
    pub subject_key: String,
}

#[rustfmt::skip]
pub type GetFrontendProjectionResult = T::FrontendProjection;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct IdentifyRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum IdsRequestKind {
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct IdsRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub kind: Optional<IdsRequestKind>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JournalFrontendEventRequest {
    pub event: T::FrontendJournalEvent,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct JournalFrontendEventResult {
    pub committed: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListAgentsRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub state: Optional<T::AgentState>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListClientsRequest {
}

#[rustfmt::skip]
pub type ListClientsResult = Vec<T::ClientInfo>;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListTerminalsRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListWorkspacesRequest {
}

#[rustfmt::skip]
pub type ListWorkspacesResult = T::Tree;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MarkWorkspacesProviderManagedRequest {
    pub authority: String,
}

#[rustfmt::skip]
pub type MarkWorkspacesProviderManagedResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MintTerminalRendererRequest {
    pub surface: T::Id,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub ttl_ms: Option<u64>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MintTerminalRendererByTerminalRequest {
    pub terminal: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub ttl_ms: Option<u64>,
}

#[rustfmt::skip]
pub type MintTerminalRendererByTerminalResult = T::MintTerminalRendererResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabRequest {
    pub index: u64,
    pub pane: T::Id,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type MoveTabResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTerminalRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub terminal_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_incarnation: Optional<String>,
    pub workspace_key: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    pub index: u64,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type MoveWorkspaceResult = T::WorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewBrowserTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    pub url: String,
}

#[rustfmt::skip]
pub type NewBrowserTabResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewPaneRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
}

#[rustfmt::skip]
pub type NewPaneResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewPaneRightRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub width: Optional<f32>,
}

#[rustfmt::skip]
pub type NewPaneRightResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct NewScreenRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type NewScreenResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct NewTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
}

#[rustfmt::skip]
pub type NewTabResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct NewWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
}

#[rustfmt::skip]
pub type NewWorkspaceResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotifyRequest {
    pub body: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub level: Optional<T::NotificationLevel>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
    pub title: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PairingResponseRequest {
    pub approve: bool,
    pub request: u64,
}

#[rustfmt::skip]
pub type PairingResponseResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PaneNeighborRequest {
    pub dir: T::PaneDirection,
    pub pane: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct PingRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProcessInfoRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PutFrontendProjectionRequest {
    /// Accepted by the current decoder but ignored for projection writes.
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_projection_revision: Optional<u64>,
    /// Accepted by the current decoder but ignored for projection writes.
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    pub frontend: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub projection: Nullable<T::JsonValue>,
    pub schema_version: u32,
    pub scope: String,
    pub subject_key: String,
}

#[rustfmt::skip]
pub type PutFrontendProjectionResult = T::FrontendProjection;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadScreenRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReadScrollbackRequest {
    pub count: u32,
    pub start: u32,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegisterBrowserProviderRequest {
    pub authentication: T::BrowserProviderAuthentication,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub bearer_token: Optional<String>,
    pub endpoint: String,
    pub provider_id: String,
    pub targets: Vec<T::BrowserProviderTarget>,
}

#[rustfmt::skip]
pub type RegisterBrowserProviderResult = T::BrowserProviderSnapshot;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReleaseAttachedViewSizeRequest {
    pub lease: String,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type ReleaseAttachedViewSizeResult = T::AttachedViewOutcomeResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReleaseSurfaceSizeRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type ReleaseSurfaceSizeResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ReloadConfigRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReloadConfigResult {
    pub path: Nullable<String>,
    pub reloaded: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenamePaneRequest {
    pub name: String,
    pub pane: T::Id,
}

#[rustfmt::skip]
pub type RenamePaneResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenameProviderManagedWorkspaceRequest {
    pub authority: String,
    pub key: String,
    pub name: String,
    pub workspace: T::Id,
}

#[rustfmt::skip]
pub type RenameProviderManagedWorkspaceResult = T::ProviderWorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenameScreenRequest {
    pub name: String,
    pub screen: T::Id,
}

#[rustfmt::skip]
pub type RenameScreenResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenameSurfaceRequest {
    pub name: String,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type RenameSurfaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RenameWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type RenameWorkspaceResult = T::WorkspaceMutationResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReportAgentRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub session: Optional<String>,
    pub source: T::AgentReportSource,
    pub state: T::AgentState,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReportFocusRequest {
    pub client_id: String,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub tab: Optional<u64>,
}

#[rustfmt::skip]
pub type ReportFocusResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResizeAttachedViewRequest {
    pub cols: u16,
    pub lease: String,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type ResizeAttachedViewResult = T::AttachedViewResizeResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResizeSurfaceRequest {
    pub cols: u16,
    pub rows: u16,
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResolveTerminalRequest {
    pub terminal_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct RunRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub argv: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub command: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub new_workspace: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScrollSurfaceRequest {
    pub delta: i64,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type ScrollSurfaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SelectScreenRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub delta: Optional<i64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
}

#[rustfmt::skip]
pub type SelectScreenResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SelectTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub delta: Optional<i64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
}

#[rustfmt::skip]
pub type SelectTabResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SelectWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub delta: Optional<i64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
}

#[rustfmt::skip]
pub type SelectWorkspaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SendRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub bytes: Optional<T::Base64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub paste: Option<bool>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub text: Optional<String>,
}

#[rustfmt::skip]
pub type SendResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SendKeyRequest {
    pub keys: Vec<String>,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type SendKeyResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetCellPixelsRequest {
    pub height_px: u16,
    pub width_px: u16,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SetClientInfoRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub capabilities: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub kind: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
}

#[rustfmt::skip]
pub type SetClientInfoResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetClientSizingRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub client: Optional<u64>,
    pub enabled: bool,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub exclusive: Option<bool>,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type SetClientSizingResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SetDefaultColorsRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub bg: Optional<T::ColorHex>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub complete: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor: Optional<T::ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_blink: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cursor_style: Optional<T::CursorStyle>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub fg: Optional<T::ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub palette: Optional<BTreeMap<String, T::ColorHex>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub selection_bg: Optional<T::ColorHex>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub selection_fg: Optional<T::ColorHex>,
}

#[rustfmt::skip]
pub type SetDefaultColorsResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetRatioRequest {
    pub dir: T::SplitDirection,
    pub pane: T::Id,
    pub ratio: f32,
}

#[rustfmt::skip]
pub type SetRatioResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetSplitRatioRequest {
    pub ratio: f32,
    pub split: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<u64>,
}

#[rustfmt::skip]
pub type SetSplitRatioResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetViewportPaneWidthRequest {
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<u64>,
    pub width: f32,
}

#[rustfmt::skip]
pub type SetViewportPaneWidthResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetWindowTitleRequest {
    pub title: String,
}

#[rustfmt::skip]
pub type SetWindowTitleResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShutdownDaemonRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    pub generation: String,
    pub pid: u32,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SidebarPluginRequest {
    pub cols: u16,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub relaunch: Option<bool>,
    pub rows: u16,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SplitRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    pub dir: T::SplitDirection,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
}

#[rustfmt::skip]
pub type SplitResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SubscribeRequestTreeEvents {
    #[serde(rename = "coarse")]
    Coarse,
    #[serde(rename = "deltas")]
    Deltas,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SubscribeRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub tree_events: Optional<SubscribeRequestTreeEvents>,
}

#[rustfmt::skip]
pub type SubscribeResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SwapPaneRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub dir: Optional<T::PaneDirection>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub target: Optional<T::Id>,
}

#[rustfmt::skip]
pub type SwapPaneResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct TerminalEventsRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub after_revision: Option<u64>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UndoLayoutRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub confirm_close: Option<bool>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub revision: Optional<u64>,
}

#[rustfmt::skip]
pub type UndoLayoutResult = T::LayoutUndoResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct UnregisterBrowserProviderRequest {
}

#[rustfmt::skip]
pub type UnregisterBrowserProviderResult = T::BrowserProviderUnregisterResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VtStateRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaitForRequest {
    pub pattern: String,
    pub surface: T::Id,
    /// Zero performs one immediate check.
    pub timeout_ms: u64,
}

#[rustfmt::skip]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ZoomPaneRequestMode {
    #[serde(rename = "toggle")]
    Toggle,
    #[serde(rename = "on")]
    On,
    #[serde(rename = "off")]
    Off,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ZoomPaneRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mode: Optional<ZoomPaneRequestMode>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
}

#[rustfmt::skip]
impl CmuxClient {
    pub fn apply_layout(&mut self, request: ApplyLayoutRequest) -> Result<T::ApplyLayoutResult> {
        self.execute(&APPLY_LAYOUT_METADATA, &request)
    }

    pub fn attach_surface(&mut self, request: AttachSurfaceRequest) -> Result<CmuxStream> {
        if !request.cols.is_missing() {
            self.require_capability_field("attach-surface", "attach-initial-size")?;
        }
        if !request.mode.is_missing() {
            self.require_protocol_field("attach-surface", 7)?;
        }
        if !request.rows.is_missing() {
            self.require_capability_field("attach-surface", "attach-initial-size")?;
        }
        self.execute_stream(&ATTACH_SURFACE_METADATA, &request)
    }

    pub fn browser_activate(&mut self, request: BrowserActivateRequest) -> Result<BrowserActivateResult> {
        self.execute(&BROWSER_ACTIVATE_METADATA, &request)
    }

    pub fn browser_back(&mut self, request: BrowserBackRequest) -> Result<BrowserBackResult> {
        self.execute(&BROWSER_BACK_METADATA, &request)
    }

    pub fn browser_forward(&mut self, request: BrowserForwardRequest) -> Result<BrowserForwardResult> {
        self.execute(&BROWSER_FORWARD_METADATA, &request)
    }

    pub fn browser_frame_presented(&mut self, request: BrowserFramePresentedRequest) -> Result<BrowserFramePresentedResult> {
        self.execute(&BROWSER_FRAME_PRESENTED_METADATA, &request)
    }

    pub fn browser_insert_text(&mut self, request: BrowserInsertTextRequest) -> Result<BrowserInsertTextResult> {
        self.execute(&BROWSER_INSERT_TEXT_METADATA, &request)
    }

    pub fn browser_key(&mut self, request: BrowserKeyRequest) -> Result<BrowserKeyResult> {
        self.execute(&BROWSER_KEY_METADATA, &request)
    }

    pub fn browser_key_press(&mut self, request: BrowserKeyPressRequest) -> Result<BrowserKeyPressResult> {
        self.execute(&BROWSER_KEY_PRESS_METADATA, &request)
    }

    pub fn browser_mouse(&mut self, request: BrowserMouseRequest) -> Result<BrowserMouseResult> {
        self.execute(&BROWSER_MOUSE_METADATA, &request)
    }

    pub fn browser_mouse_guarded(&mut self, request: BrowserMouseGuardedRequest) -> Result<BrowserMouseGuardedResult> {
        self.execute(&BROWSER_MOUSE_GUARDED_METADATA, &request)
    }

    pub fn browser_navigate(&mut self, request: BrowserNavigateRequest) -> Result<BrowserNavigateResult> {
        self.execute(&BROWSER_NAVIGATE_METADATA, &request)
    }

    pub fn browser_reload(&mut self, request: BrowserReloadRequest) -> Result<BrowserReloadResult> {
        self.execute(&BROWSER_RELOAD_METADATA, &request)
    }

    pub fn browser_wheel(&mut self, request: BrowserWheelRequest) -> Result<BrowserWheelResult> {
        self.execute(&BROWSER_WHEEL_METADATA, &request)
    }

    pub fn browser_wheel_guarded(&mut self, request: BrowserWheelGuardedRequest) -> Result<BrowserWheelGuardedResult> {
        self.execute(&BROWSER_WHEEL_GUARDED_METADATA, &request)
    }

    pub fn clear_history(&mut self, request: ClearHistoryRequest) -> Result<ClearHistoryResult> {
        if !request.fallback_key.is_missing() {
            self.require_protocol_field("clear-history", 9)?;
            self.require_capability_field("clear-history", "clear-history-key-v1")?;
        }
        self.execute(&CLEAR_HISTORY_METADATA, &request)
    }

    pub fn clear_window_title(&mut self, request: ClearWindowTitleRequest) -> Result<ClearWindowTitleResult> {
        self.execute(&CLEAR_WINDOW_TITLE_METADATA, &request)
    }

    pub fn client_focus(&mut self, request: ClientFocusRequest) -> Result<ClientFocusResult> {
        self.execute(&CLIENT_FOCUS_METADATA, &request)
    }

    pub fn close_pane(&mut self, request: ClosePaneRequest) -> Result<ClosePaneResult> {
        self.execute(&CLOSE_PANE_METADATA, &request)
    }

    pub fn close_provider_managed_workspace(&mut self, request: CloseProviderManagedWorkspaceRequest) -> Result<CloseProviderManagedWorkspaceResult> {
        self.execute(&CLOSE_PROVIDER_MANAGED_WORKSPACE_METADATA, &request)
    }

    pub fn close_screen(&mut self, request: CloseScreenRequest) -> Result<CloseScreenResult> {
        self.execute(&CLOSE_SCREEN_METADATA, &request)
    }

    pub fn close_surface(&mut self, request: CloseSurfaceRequest) -> Result<CloseSurfaceResult> {
        self.execute(&CLOSE_SURFACE_METADATA, &request)
    }

    pub fn close_terminal(&mut self, request: CloseTerminalRequest) -> Result<T::CloseTerminalResult> {
        self.execute(&CLOSE_TERMINAL_METADATA, &request)
    }

    pub fn close_workspace(&mut self, request: CloseWorkspaceRequest) -> Result<CloseWorkspaceResult> {
        if !request.expected_generation.is_missing() {
            self.require_protocol_field("close-workspace", 7)?;
        }
        if !request.expected_revision.is_missing() {
            self.require_protocol_field("close-workspace", 7)?;
        }
        if !request.key.is_missing() {
            self.require_protocol_field("close-workspace", 7)?;
            self.require_capability_field("close-workspace", "workspace-registry-v1")?;
        }
        if !request.mutation_id.is_missing() {
            self.require_protocol_field("close-workspace", 7)?;
        }
        if !request.origin.is_missing() {
            self.require_protocol_field("close-workspace", 7)?;
        }
        self.execute(&CLOSE_WORKSPACE_METADATA, &request)
    }

    pub fn copy(&mut self, request: CopyRequest) -> Result<T::CopyResult> {
        self.execute(&COPY_METADATA, &request)
    }

    pub fn create_surface_with_receipt(&mut self, request: CreateSurfaceWithReceiptRequest) -> Result<CreateSurfaceWithReceiptResult> {
        if !request.idempotency_key.is_missing() {
            self.require_capability_field("create-surface-with-receipt", "creation-attempt-keys-v1")?;
        }
        self.execute(&CREATE_SURFACE_WITH_RECEIPT_METADATA, &request)
    }

    pub fn create_terminal(&mut self, request: CreateTerminalRequest) -> Result<CreateTerminalResult> {
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("create-terminal", 9)?;
        }
        self.execute(&CREATE_TERMINAL_METADATA, &request)
    }

    pub fn create_workspace(&mut self, request: CreateWorkspaceRequest) -> Result<CreateWorkspaceResult> {
        self.execute(&CREATE_WORKSPACE_METADATA, &request)
    }

    pub fn detach_attached_view(&mut self, request: DetachAttachedViewRequest) -> Result<DetachAttachedViewResult> {
        self.execute(&DETACH_ATTACHED_VIEW_METADATA, &request)
    }

    pub fn detach_client(&mut self, request: DetachClientRequest) -> Result<DetachClientResult> {
        self.execute(&DETACH_CLIENT_METADATA, &request)
    }

    pub fn export_layout(&mut self, request: ExportLayoutRequest) -> Result<T::ExportLayoutResult> {
        self.execute(&EXPORT_LAYOUT_METADATA, &request)
    }

    pub fn focus_direction(&mut self, request: FocusDirectionRequest) -> Result<T::FocusDirectionResult> {
        self.execute(&FOCUS_DIRECTION_METADATA, &request)
    }

    pub fn focus_pane(&mut self, request: FocusPaneRequest) -> Result<FocusPaneResult> {
        self.execute(&FOCUS_PANE_METADATA, &request)
    }

    pub fn get_browser_provider(&mut self, request: GetBrowserProviderRequest) -> Result<GetBrowserProviderResult> {
        self.execute(&GET_BROWSER_PROVIDER_METADATA, &request)
    }

    pub fn get_cell_pixels(&mut self, request: GetCellPixelsRequest) -> Result<T::GetCellPixelsResult> {
        self.execute(&GET_CELL_PIXELS_METADATA, &request)
    }

    pub fn get_frontend_projection(&mut self, request: GetFrontendProjectionRequest) -> Result<GetFrontendProjectionResult> {
        self.execute(&GET_FRONTEND_PROJECTION_METADATA, &request)
    }

    pub fn identify(&mut self, request: IdentifyRequest) -> Result<T::IdentifyResult> {
        self.execute_identify(&IDENTIFY_METADATA, &request)
    }

    pub fn ids(&mut self, request: IdsRequest) -> Result<T::IdsResult> {
        self.execute(&IDS_METADATA, &request)
    }

    pub fn journal_frontend_event(&mut self, request: JournalFrontendEventRequest) -> Result<JournalFrontendEventResult> {
        self.execute(&JOURNAL_FRONTEND_EVENT_METADATA, &request)
    }

    pub fn list_agents(&mut self, request: ListAgentsRequest) -> Result<T::ListAgentsResult> {
        self.execute(&LIST_AGENTS_METADATA, &request)
    }

    pub fn list_clients(&mut self, request: ListClientsRequest) -> Result<ListClientsResult> {
        self.execute(&LIST_CLIENTS_METADATA, &request)
    }

    pub fn list_terminals(&mut self, request: ListTerminalsRequest) -> Result<T::ListTerminalsResult> {
        self.execute(&LIST_TERMINALS_METADATA, &request)
    }

    pub fn list_workspaces(&mut self, request: ListWorkspacesRequest) -> Result<ListWorkspacesResult> {
        self.execute(&LIST_WORKSPACES_METADATA, &request)
    }

    pub fn mark_workspaces_provider_managed(&mut self, request: MarkWorkspacesProviderManagedRequest) -> Result<MarkWorkspacesProviderManagedResult> {
        self.execute(&MARK_WORKSPACES_PROVIDER_MANAGED_METADATA, &request)
    }

    pub fn mint_terminal_renderer(&mut self, request: MintTerminalRendererRequest) -> Result<T::MintTerminalRendererResult> {
        self.execute(&MINT_TERMINAL_RENDERER_METADATA, &request)
    }

    pub fn mint_terminal_renderer_by_terminal(&mut self, request: MintTerminalRendererByTerminalRequest) -> Result<MintTerminalRendererByTerminalResult> {
        self.execute(&MINT_TERMINAL_RENDERER_BY_TERMINAL_METADATA, &request)
    }

    pub fn move_tab(&mut self, request: MoveTabRequest) -> Result<MoveTabResult> {
        self.execute(&MOVE_TAB_METADATA, &request)
    }

    pub fn move_terminal(&mut self, request: MoveTerminalRequest) -> Result<T::MoveTerminalResult> {
        self.execute(&MOVE_TERMINAL_METADATA, &request)
    }

    pub fn move_workspace(&mut self, request: MoveWorkspaceRequest) -> Result<MoveWorkspaceResult> {
        if !request.expected_generation.is_missing() {
            self.require_protocol_field("move-workspace", 7)?;
        }
        if !request.expected_revision.is_missing() {
            self.require_protocol_field("move-workspace", 7)?;
        }
        if !request.key.is_missing() {
            self.require_protocol_field("move-workspace", 7)?;
            self.require_capability_field("move-workspace", "workspace-registry-v1")?;
        }
        if !request.mutation_id.is_missing() {
            self.require_protocol_field("move-workspace", 7)?;
        }
        if !request.origin.is_missing() {
            self.require_protocol_field("move-workspace", 7)?;
        }
        self.execute(&MOVE_WORKSPACE_METADATA, &request)
    }

    pub fn new_browser_tab(&mut self, request: NewBrowserTabRequest) -> Result<NewBrowserTabResult> {
        self.execute(&NEW_BROWSER_TAB_METADATA, &request)
    }

    pub fn new_pane(&mut self, request: NewPaneRequest) -> Result<NewPaneResult> {
        self.execute(&NEW_PANE_METADATA, &request)
    }

    pub fn new_pane_right(&mut self, request: NewPaneRightRequest) -> Result<NewPaneRightResult> {
        self.execute(&NEW_PANE_RIGHT_METADATA, &request)
    }

    pub fn new_screen(&mut self, request: NewScreenRequest) -> Result<NewScreenResult> {
        self.execute(&NEW_SCREEN_METADATA, &request)
    }

    pub fn new_tab(&mut self, request: NewTabRequest) -> Result<NewTabResult> {
        self.execute(&NEW_TAB_METADATA, &request)
    }

    pub fn new_workspace(&mut self, request: NewWorkspaceRequest) -> Result<NewWorkspaceResult> {
        self.execute(&NEW_WORKSPACE_METADATA, &request)
    }

    pub fn notify(&mut self, request: NotifyRequest) -> Result<T::NotifyResult> {
        self.execute(&NOTIFY_METADATA, &request)
    }

    pub fn pairing_response(&mut self, request: PairingResponseRequest) -> Result<PairingResponseResult> {
        self.execute(&PAIRING_RESPONSE_METADATA, &request)
    }

    pub fn pane_neighbor(&mut self, request: PaneNeighborRequest) -> Result<T::PaneNeighborResult> {
        self.execute(&PANE_NEIGHBOR_METADATA, &request)
    }

    pub fn ping(&mut self, request: PingRequest) -> Result<T::PingResult> {
        self.execute(&PING_METADATA, &request)
    }

    pub fn process_info(&mut self, request: ProcessInfoRequest) -> Result<T::ProcessInfoResult> {
        self.execute(&PROCESS_INFO_METADATA, &request)
    }

    pub fn put_frontend_projection(&mut self, request: PutFrontendProjectionRequest) -> Result<PutFrontendProjectionResult> {
        self.execute(&PUT_FRONTEND_PROJECTION_METADATA, &request)
    }

    pub fn read_screen(&mut self, request: ReadScreenRequest) -> Result<T::ReadScreenResult> {
        self.execute(&READ_SCREEN_METADATA, &request)
    }

    pub fn read_scrollback(&mut self, request: ReadScrollbackRequest) -> Result<T::ReadScrollbackResult> {
        self.execute(&READ_SCROLLBACK_METADATA, &request)
    }

    pub fn register_browser_provider(&mut self, request: RegisterBrowserProviderRequest) -> Result<RegisterBrowserProviderResult> {
        self.execute(&REGISTER_BROWSER_PROVIDER_METADATA, &request)
    }

    pub fn release_attached_view_size(&mut self, request: ReleaseAttachedViewSizeRequest) -> Result<ReleaseAttachedViewSizeResult> {
        self.execute(&RELEASE_ATTACHED_VIEW_SIZE_METADATA, &request)
    }

    pub fn release_surface_size(&mut self, request: ReleaseSurfaceSizeRequest) -> Result<ReleaseSurfaceSizeResult> {
        self.execute(&RELEASE_SURFACE_SIZE_METADATA, &request)
    }

    pub fn reload_config(&mut self, request: ReloadConfigRequest) -> Result<ReloadConfigResult> {
        self.execute(&RELOAD_CONFIG_METADATA, &request)
    }

    pub fn rename_pane(&mut self, request: RenamePaneRequest) -> Result<RenamePaneResult> {
        self.execute(&RENAME_PANE_METADATA, &request)
    }

    pub fn rename_provider_managed_workspace(&mut self, request: RenameProviderManagedWorkspaceRequest) -> Result<RenameProviderManagedWorkspaceResult> {
        self.execute(&RENAME_PROVIDER_MANAGED_WORKSPACE_METADATA, &request)
    }

    pub fn rename_screen(&mut self, request: RenameScreenRequest) -> Result<RenameScreenResult> {
        self.execute(&RENAME_SCREEN_METADATA, &request)
    }

    pub fn rename_surface(&mut self, request: RenameSurfaceRequest) -> Result<RenameSurfaceResult> {
        self.execute(&RENAME_SURFACE_METADATA, &request)
    }

    pub fn rename_workspace(&mut self, request: RenameWorkspaceRequest) -> Result<RenameWorkspaceResult> {
        if !request.expected_generation.is_missing() {
            self.require_protocol_field("rename-workspace", 7)?;
        }
        if !request.expected_revision.is_missing() {
            self.require_protocol_field("rename-workspace", 7)?;
        }
        if !request.key.is_missing() {
            self.require_protocol_field("rename-workspace", 7)?;
            self.require_capability_field("rename-workspace", "workspace-registry-v1")?;
        }
        if !request.mutation_id.is_missing() {
            self.require_protocol_field("rename-workspace", 7)?;
        }
        if !request.origin.is_missing() {
            self.require_protocol_field("rename-workspace", 7)?;
        }
        self.execute(&RENAME_WORKSPACE_METADATA, &request)
    }

    pub fn report_agent(&mut self, request: ReportAgentRequest) -> Result<T::ReportAgentResult> {
        self.execute(&REPORT_AGENT_METADATA, &request)
    }

    pub fn report_focus(&mut self, request: ReportFocusRequest) -> Result<ReportFocusResult> {
        self.execute(&REPORT_FOCUS_METADATA, &request)
    }

    pub fn resize_attached_view(&mut self, request: ResizeAttachedViewRequest) -> Result<ResizeAttachedViewResult> {
        self.execute(&RESIZE_ATTACHED_VIEW_METADATA, &request)
    }

    pub fn resize_surface(&mut self, request: ResizeSurfaceRequest) -> Result<T::ResizeSurfaceResult> {
        self.execute(&RESIZE_SURFACE_METADATA, &request)
    }

    pub fn resolve_terminal(&mut self, request: ResolveTerminalRequest) -> Result<T::ResolveTerminalResult> {
        self.execute(&RESOLVE_TERMINAL_METADATA, &request)
    }

    pub fn run(&mut self, request: RunRequest) -> Result<T::RunResult> {
        if !request.key.is_missing() {
            self.require_protocol_field("run", 9)?;
        }
        self.execute(&RUN_METADATA, &request)
    }

    pub fn scroll_surface(&mut self, request: ScrollSurfaceRequest) -> Result<ScrollSurfaceResult> {
        self.execute(&SCROLL_SURFACE_METADATA, &request)
    }

    pub fn select_screen(&mut self, request: SelectScreenRequest) -> Result<SelectScreenResult> {
        self.execute(&SELECT_SCREEN_METADATA, &request)
    }

    pub fn select_tab(&mut self, request: SelectTabRequest) -> Result<SelectTabResult> {
        self.execute(&SELECT_TAB_METADATA, &request)
    }

    pub fn select_workspace(&mut self, request: SelectWorkspaceRequest) -> Result<SelectWorkspaceResult> {
        self.execute(&SELECT_WORKSPACE_METADATA, &request)
    }

    pub fn send(&mut self, request: SendRequest) -> Result<SendResult> {
        if request.paste.is_some() {
            self.require_protocol_field("send", 7)?;
        }
        self.execute(&SEND_METADATA, &request)
    }

    pub fn send_key(&mut self, request: SendKeyRequest) -> Result<SendKeyResult> {
        self.execute(&SEND_KEY_METADATA, &request)
    }

    pub fn set_cell_pixels(&mut self, request: SetCellPixelsRequest) -> Result<T::SetCellPixelsResult> {
        self.execute(&SET_CELL_PIXELS_METADATA, &request)
    }

    pub fn set_client_info(&mut self, request: SetClientInfoRequest) -> Result<SetClientInfoResult> {
        self.execute(&SET_CLIENT_INFO_METADATA, &request)
    }

    pub fn set_client_sizing(&mut self, request: SetClientSizingRequest) -> Result<SetClientSizingResult> {
        self.execute(&SET_CLIENT_SIZING_METADATA, &request)
    }

    pub fn set_default_colors(&mut self, request: SetDefaultColorsRequest) -> Result<SetDefaultColorsResult> {
        if request.complete.is_some() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.cursor.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.cursor_blink.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.cursor_style.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.palette.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.selection_bg.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        if !request.selection_fg.is_missing() {
            self.require_protocol_field("set-default-colors", 9)?;
        }
        self.execute(&SET_DEFAULT_COLORS_METADATA, &request)
    }

    pub fn set_ratio(&mut self, request: SetRatioRequest) -> Result<SetRatioResult> {
        self.execute(&SET_RATIO_METADATA, &request)
    }

    pub fn set_split_ratio(&mut self, request: SetSplitRatioRequest) -> Result<SetSplitRatioResult> {
        if !request.transaction.is_missing() {
            self.require_protocol_field("set-split-ratio", 9)?;
            self.require_capability_field("set-split-ratio", "layout-undo-v1")?;
        }
        self.execute(&SET_SPLIT_RATIO_METADATA, &request)
    }

    pub fn set_viewport_pane_width(&mut self, request: SetViewportPaneWidthRequest) -> Result<SetViewportPaneWidthResult> {
        if !request.transaction.is_missing() {
            self.require_protocol_field("set-viewport-pane-width", 9)?;
            self.require_capability_field("set-viewport-pane-width", "layout-undo-v1")?;
        }
        self.execute(&SET_VIEWPORT_PANE_WIDTH_METADATA, &request)
    }

    pub fn set_window_title(&mut self, request: SetWindowTitleRequest) -> Result<SetWindowTitleResult> {
        self.execute(&SET_WINDOW_TITLE_METADATA, &request)
    }

    pub fn shutdown_daemon(&mut self, request: ShutdownDaemonRequest) -> Result<T::ShutdownDaemonResult> {
        if request.force.is_some() {
            self.require_protocol_field("shutdown-daemon", 10)?;
            self.require_capability_field("shutdown-daemon", "daemon-handoff-force-v1")?;
        }
        self.execute(&SHUTDOWN_DAEMON_METADATA, &request)
    }

    pub fn sidebar_plugin(&mut self, request: SidebarPluginRequest) -> Result<T::SidebarPluginResult> {
        self.execute(&SIDEBAR_PLUGIN_METADATA, &request)
    }

    pub fn split(&mut self, request: SplitRequest) -> Result<SplitResult> {
        self.execute(&SPLIT_METADATA, &request)
    }

    pub fn subscribe(&mut self, request: SubscribeRequest) -> Result<CmuxStream> {
        if !request.surface.is_missing() {
            self.require_protocol_field("subscribe", 9)?;
            self.require_capability_field("subscribe", "surface-subscribe-filter")?;
        }
        if !request.tree_events.is_missing() {
            self.require_protocol_field("subscribe", 7)?;
        }
        self.execute_stream(&SUBSCRIBE_METADATA, &request)
    }

    pub fn swap_pane(&mut self, request: SwapPaneRequest) -> Result<SwapPaneResult> {
        self.execute(&SWAP_PANE_METADATA, &request)
    }

    pub fn terminal_events(&mut self, request: TerminalEventsRequest) -> Result<T::TerminalEventsResult> {
        self.execute(&TERMINAL_EVENTS_METADATA, &request)
    }

    pub fn undo_layout(&mut self, request: UndoLayoutRequest) -> Result<UndoLayoutResult> {
        self.execute(&UNDO_LAYOUT_METADATA, &request)
    }

    pub fn unregister_browser_provider(&mut self, request: UnregisterBrowserProviderRequest) -> Result<UnregisterBrowserProviderResult> {
        self.execute(&UNREGISTER_BROWSER_PROVIDER_METADATA, &request)
    }

    pub fn vt_state(&mut self, request: VtStateRequest) -> Result<T::VtStateResult> {
        self.execute(&VT_STATE_METADATA, &request)
    }

    pub fn wait_for(&mut self, request: WaitForRequest) -> Result<T::WaitForResult> {
        self.execute(&WAIT_FOR_METADATA, &request)
    }

    pub fn zoom_pane(&mut self, request: ZoomPaneRequest) -> Result<T::ZoomPaneResult> {
        self.execute(&ZOOM_PANE_METADATA, &request)
    }

}

// This file is generated. Do not edit by hand.
// cmux-tui mux protocol 12, IR 573bdc398c4544c8b2d1aab7c7af4261385c90e9fb190efc978082da4208ccf8.
// The emitter owns this layout so generation is independent of the installed rustfmt.

use super::metadata::*;
use super::types as T;
use crate::{CmuxClient, CmuxStream, Nullable, Optional, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AckTabNotificationsRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type AckTabNotificationsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AddScreensToScreenGroupRequest {
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub screens: Vec<T::Id>,
}

#[rustfmt::skip]
pub type AddScreensToScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AddTabsToTabGroupRequest {
    pub group: String,
    #[serde(alias = "tabs")]
    pub surfaces: Vec<T::TabRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type AddTabsToTabGroupResult = T::JsonValue;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct AttachSurfaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mode: Optional<AttachSurfaceRequestMode>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
    pub screen: T::Id,
}

#[rustfmt::skip]
pub type CloseScreenResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseScreenGroupRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
    pub group: String,
}

#[rustfmt::skip]
pub type CloseScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseSurfaceRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type CloseSurfaceResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseTabGroupRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
    pub group: String,
}

#[rustfmt::skip]
pub type CloseTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CloseTabsRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub surfaces: Vec<T::TabRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type CloseTabsResult = T::JsonValue;

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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
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
pub struct CreateBookmarkRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub bookmark: Optional<String>,
    pub browser_profile_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub created_ms: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub favicon_key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub parent: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub source_key: Optional<String>,
    pub title: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub url: Optional<String>,
}

#[rustfmt::skip]
pub type CreateBookmarkResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateBrowserProfileRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_profile: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub source: Optional<T::JsonValue>,
}

#[rustfmt::skip]
pub type CreateBrowserProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreatePersonalGroupRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub profile: Optional<String>,
}

#[rustfmt::skip]
pub type CreatePersonalGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateProfileRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_profile_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub default_session_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub defaults: Optional<T::JsonValue>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub follows: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub profile: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub theme: Optional<String>,
}

#[rustfmt::skip]
pub type CreateProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateScreenGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    pub screens: Vec<T::Id>,
}

#[rustfmt::skip]
pub type CreateScreenGroupResult = T::JsonValue;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CreateTabGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(alias = "tabs")]
    pub surfaces: Vec<T::TabRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type CreateTabGroupResult = T::JsonValue;

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
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub detached: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub env: Optional<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
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
    pub shell_args: Optional<Vec<String>>,
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
pub struct CreateWorkspaceGroupRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub name: String,
}

#[rustfmt::skip]
pub type CreateWorkspaceGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteBookmarkRequest {
    pub bookmark: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
}

#[rustfmt::skip]
pub type DeleteBookmarkResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteBrowserProfileRequest {
    pub browser_profile: String,
}

#[rustfmt::skip]
pub type DeleteBrowserProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeletePersonalGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type DeletePersonalGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteProfileRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub move_to: Optional<String>,
    pub profile: String,
}

#[rustfmt::skip]
pub type DeleteProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteSavedScreenGroupRequest {
    pub saved: String,
}

#[rustfmt::skip]
pub type DeleteSavedScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteSavedTabGroupRequest {
    pub saved: String,
}

#[rustfmt::skip]
pub type DeleteSavedTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeleteWorkspaceGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type DeleteWorkspaceGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetachAttachedViewRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub lease: Optional<String>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub view: Optional<String>,
}

#[rustfmt::skip]
pub type DetachAttachedViewResult = T::AttachedViewOutcomeResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DetachClientRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub by: Optional<T::SizeDetachActor>,
    pub client: T::DetachClientTarget,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ForgetSessionRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    pub session_id: String,
}

#[rustfmt::skip]
pub type ForgetSessionResult = T::JsonValue;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GetSizeStateRequest {
    pub surface: T::Id,
}

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
pub struct ImportBookmarksRequest {
    pub browser_profile_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    pub nodes: Vec<T::JsonValue>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub parent: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub replace: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub source_key: Optional<String>,
}

#[rustfmt::skip]
pub type ImportBookmarksResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImportSessionOrganizationRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub groups: Option<Vec<T::JsonValue>>,
    pub session_id: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub workspaces: Option<Vec<T::JsonValue>>,
}

#[rustfmt::skip]
pub type ImportSessionOrganizationResult = T::JsonValue;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ListBookmarksRequest {
    pub browser_profile_id: String,
}

#[rustfmt::skip]
pub type ListBookmarksResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListClientsRequest {
}

#[rustfmt::skip]
pub type ListClientsResult = Vec<T::ClientInfo>;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListNotificationsRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub limit: Optional<u64>,
}

#[rustfmt::skip]
pub type ListNotificationsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListPersonalRequest {
}

#[rustfmt::skip]
pub type ListPersonalResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListSavedScreenGroupsRequest {
}

#[rustfmt::skip]
pub type ListSavedScreenGroupsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListSavedTabGroupsRequest {
}

#[rustfmt::skip]
pub type ListSavedTabGroupsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListTabGroupsRequest {
}

#[rustfmt::skip]
pub type ListTabGroupsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListTerminalsRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListWorkspaceGroupsRequest {
}

#[rustfmt::skip]
pub type ListWorkspaceGroupsResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ListWorkspacesRequest {
}

#[rustfmt::skip]
pub type ListWorkspacesResult = T::Tree;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MachineListeningTcpRequest {
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MachineUsageRequest {
}

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
pub struct MoveBookmarkRequest {
    pub bookmark: String,
    pub index: u64,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    pub parent: String,
}

#[rustfmt::skip]
pub type MoveBookmarkResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveBrowserProfileRequest {
    pub browser_profile: String,
    pub index: u64,
}

#[rustfmt::skip]
pub type MoveBrowserProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MovePersonalGroupRequest {
    pub group: String,
    pub index: u64,
}

#[rustfmt::skip]
pub type MovePersonalGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveProfileRequest {
    pub index: u64,
    pub profile: String,
}

#[rustfmt::skip]
pub type MoveProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveScreenRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub new_workspace: Option<bool>,
    pub screen: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type MoveScreenResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveScreenGroupRequest {
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub new_workspace: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type MoveScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabRequest {
    pub index: u64,
    pub pane: T::Id,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabResult = T::EmptyResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabGroupRequest {
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::PaneRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabGroupToColumnRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub after_column: Optional<T::Id>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::PaneRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub screen: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub width: Optional<f32>,
}

#[rustfmt::skip]
pub type MoveTabGroupToColumnResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabGroupToNewWorkspaceRequest {
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace_group: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabGroupToNewWorkspaceResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabGroupToSplitRequest {
    pub edge: String,
    pub group: String,
    pub pane: T::PaneRef,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub ratio: Optional<f32>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabGroupToSplitResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabToColumnRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub after_column: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub screen: Optional<T::Id>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub width: Optional<f32>,
}

#[rustfmt::skip]
pub type MoveTabToColumnResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabToNewWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabToNewWorkspaceResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabToSplitRequest {
    pub edge: String,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub ratio: Optional<f32>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type MoveTabToSplitResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MoveTabToWorkspaceRequest {
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type MoveTabToWorkspaceResult = T::EmptyResult;

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
pub struct MoveWorkspaceGroupRequest {
    pub group: String,
    pub index: u64,
}

#[rustfmt::skip]
pub type MoveWorkspaceGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct MoveWorkspaceToGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
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
pub type MoveWorkspaceToGroupResult = T::JsonValue;

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
pub struct NewFrontendBrowserTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    pub engine: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub favicon_url: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub profile_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
    pub url: String,
}

#[rustfmt::skip]
pub type NewFrontendBrowserTabResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewPaneRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub env: Optional<BTreeMap<String, String>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub shell_args: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
}

#[rustfmt::skip]
pub type NewPaneResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewPaneRightRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub env: Optional<BTreeMap<String, String>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub shell_args: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub width: Optional<f32>,
}

#[rustfmt::skip]
pub type NewPaneRightResult = T::SurfaceResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewRemoteTerminalTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    pub session_id: String,
    pub session_name: String,
    pub terminal_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
}

#[rustfmt::skip]
pub type NewRemoteTerminalTabResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct NewScreenRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cols: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pinned: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub screen_name: Optional<String>,
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
    pub env: Optional<BTreeMap<String, String>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pane: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub shell_args: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
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
pub struct NoteSizeActivityRequest {
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub view: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotifyRequest {
    pub body: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub level: Optional<T::NotificationLevel>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub source: Optional<T::NotificationSource>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PasteImageRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub data: Optional<String>,
    pub lease: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mime: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub offset: Optional<u64>,
    pub op: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub size: Optional<u64>,
    pub surface: T::Id,
    pub terminal_id: String,
    pub upload_id: String,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PasteImageResult {
    pub accepted: bool,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PinWorkspaceRequest {
    pub profile: String,
    pub session_id: String,
    pub workspace_key: String,
}

#[rustfmt::skip]
pub type PinWorkspaceResult = T::JsonValue;

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
pub struct PutSessionRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub capabilities: Optional<T::JsonValue>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub follow_with: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub machine_name: Optional<String>,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub session_name: Optional<String>,
    pub transport: Nullable<T::JsonValue>,
}

#[rustfmt::skip]
pub type PutSessionResult = T::JsonValue;

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
pub struct ReattachViewRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub counts: Optional<bool>,
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
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub lease: Optional<String>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub view: Optional<String>,
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
pub struct RemoteTerminalSnapshotRequest {
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type RemoteTerminalSnapshotResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoveScreensFromScreenGroupRequest {
    pub screens: Vec<T::Id>,
}

#[rustfmt::skip]
pub type RemoveScreensFromScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoveTabsFromTabGroupRequest {
    #[serde(alias = "tabs")]
    pub surfaces: Vec<T::TabRef>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type RemoveTabsFromTabGroupResult = T::JsonValue;

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
pub struct ReopenSavedScreenGroupRequest {
    pub saved: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type ReopenSavedScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ReopenSavedTabGroupRequest {
    pub pane: T::PaneRef,
    pub saved: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<String>,
}

#[rustfmt::skip]
pub type ReopenSavedTabGroupResult = T::JsonValue;

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
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub identity: Optional<T::SizingIdentity>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub lease: Optional<String>,
    pub rows: u16,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub view: Optional<String>,
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
pub struct SaveScreenGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type SaveScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SaveTabGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type SaveTabGroupResult = T::JsonValue;

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ServerStatsRequest {
}

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
    pub device_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub device_kind: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub device_name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub display_name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub kind: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub user_id: Optional<String>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetColumnStickyRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub edge: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mode: Optional<String>,
    pub pane: T::Id,
    pub sticky: bool,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub transaction: Optional<u64>,
}

#[rustfmt::skip]
pub type SetColumnStickyResult = T::JsonValue;

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
pub struct SetPersonalTerminalRequest {
    pub session_id: String,
    pub terminal_key: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub theme: Optional<String>,
}

#[rustfmt::skip]
pub type SetPersonalTerminalResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetPersonalWorkspaceRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_profile_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub group: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub index: Optional<u64>,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub theme: Optional<String>,
    pub workspace_key: String,
}

#[rustfmt::skip]
pub type SetPersonalWorkspaceResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetProfileFollowsRequest {
    pub profile: String,
    pub session_ids: Vec<String>,
}

#[rustfmt::skip]
pub type SetProfileFollowsResult = T::JsonValue;

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
pub struct SetScreenMetadataRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    pub screen: T::Id,
}

#[rustfmt::skip]
pub type SetScreenMetadataResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetScreenPinnedRequest {
    pub pinned: bool,
    pub screen: T::Id,
}

#[rustfmt::skip]
pub type SetScreenPinnedResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetSizeCountsRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub client: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub counts: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub lease: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub participant: Optional<String>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub view: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SetSizePolicyRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub policy: Optional<T::SizePolicy>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

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
pub struct SetTabPinnedRequest {
    pub pinned: bool,
    pub surface: T::Id,
}

#[rustfmt::skip]
pub type SetTabPinnedResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetTerminalCommandHistoryRequest {
    pub enabled: bool,
}

#[rustfmt::skip]
pub type SetTerminalCommandHistoryResult = T::TerminalCommandHistoryResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SetTerminalIdlePolicyRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub idle_close_seconds: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
}

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetTerminalKeepRequest {
    pub keep: bool,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surface: Optional<T::Id>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
}

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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SetWorkspaceMetadataRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub expected_generation: Optional<String>,
    #[serde(alias = "expected_terminal_revision", default, skip_serializing_if = "Optional::is_missing")]
    pub expected_revision: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub marked_unread: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub pinned: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub workspace: Optional<T::Id>,
}

#[rustfmt::skip]
pub type SetWorkspaceMetadataResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShutdownDaemonRequest {
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub end_terminals: Option<bool>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub force: Option<bool>,
    pub generation: String,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep_layout: Option<bool>,
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
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub cwd: Optional<String>,
    pub dir: T::SplitDirection,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub env: Optional<BTreeMap<String, String>>,
    #[serde(default, deserialize_with = "crate::presence::deserialize_optional_non_null", skip_serializing_if = "Option::is_none")]
    pub keep: Option<bool>,
    pub pane: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub rows: Optional<u16>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub shell_args: Optional<Vec<String>>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub terminal_id: Optional<String>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct TerminalResourcesRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub surfaces: Optional<Vec<T::Id>>,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UngroupScreenGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type UngroupScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UngroupTabGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type UngroupTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UnpinWorkspaceRequest {
    pub session_id: String,
    pub workspace_key: String,
}

#[rustfmt::skip]
pub type UnpinWorkspaceResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct UnregisterBrowserProviderRequest {
}

#[rustfmt::skip]
pub type UnregisterBrowserProviderResult = T::BrowserProviderUnregisterResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UnsaveScreenGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type UnsaveScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UnsaveTabGroupRequest {
    pub group: String,
}

#[rustfmt::skip]
pub type UnsaveTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateBookmarkRequest {
    pub bookmark: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub favicon_key: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub last_used_ms: Optional<u64>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub mutation_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub origin: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub url: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateBookmarkResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateBrowserProfileRequest {
    pub browser_profile: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateBrowserProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateFrontendBrowserTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub favicon_url: Optional<String>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub url: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateFrontendBrowserTabResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdatePersonalGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub collapsed: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub profile: Optional<String>,
}

#[rustfmt::skip]
pub type UpdatePersonalGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateProfileRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub browser_profile_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub default_session_id: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub defaults: Optional<T::JsonValue>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub icon: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
    pub profile: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub theme: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateProfileResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateRemoteTerminalTabRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub session_name: Optional<String>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub snapshot: Optional<String>,
    pub surface: T::Id,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub title: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateRemoteTerminalTabResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateScreenGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub collapsed: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateScreenGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateTabGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub collapsed: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateTabGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UpdateWorkspaceGroupRequest {
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub collapsed: Optional<bool>,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub color: Optional<String>,
    pub group: String,
    #[serde(default, skip_serializing_if = "Optional::is_missing")]
    pub name: Optional<String>,
}

#[rustfmt::skip]
pub type UpdateWorkspaceGroupResult = T::JsonValue;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UrlOpenRequest {
    pub terminal_id: String,
    pub url: String,
}

#[rustfmt::skip]
pub type UrlOpenResult = T::GuestUrlOpenResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UrlOpenClaimRequest {
    pub request_id: String,
}

#[rustfmt::skip]
pub type UrlOpenClaimResult = T::GuestUrlClaimResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UrlOpenResultRequest {
    pub opened: bool,
    pub request_id: String,
}

#[rustfmt::skip]
pub type UrlOpenResultResult = T::GuestUrlAcknowledgeResult;

#[rustfmt::skip]
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UrlOpenSubscribeRequest {
    pub terminal_ids: Vec<String>,
}

#[rustfmt::skip]
pub type UrlOpenSubscribeResult = T::GuestUrlSubscribeResult;

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
    pub fn ack_tab_notifications(&mut self, request: AckTabNotificationsRequest) -> Result<AckTabNotificationsResult> {
        self.execute(&ACK_TAB_NOTIFICATIONS_METADATA, &request)
    }

    pub fn add_screens_to_screen_group(&mut self, request: AddScreensToScreenGroupRequest) -> Result<AddScreensToScreenGroupResult> {
        self.execute(&ADD_SCREENS_TO_SCREEN_GROUP_METADATA, &request)
    }

    pub fn add_tabs_to_tab_group(&mut self, request: AddTabsToTabGroupRequest) -> Result<AddTabsToTabGroupResult> {
        self.execute(&ADD_TABS_TO_TAB_GROUP_METADATA, &request)
    }

    pub fn apply_layout(&mut self, request: ApplyLayoutRequest) -> Result<T::ApplyLayoutResult> {
        self.execute(&APPLY_LAYOUT_METADATA, &request)
    }

    pub fn attach_surface(&mut self, request: AttachSurfaceRequest) -> Result<CmuxStream> {
        if !request.cols.is_missing() {
            self.require_capability_field("attach-surface", "attach-initial-size")?;
        }
        if !request.expected_generation.is_missing() {
            self.require_capability_field("attach-surface", "attach-identity-v1")?;
        }
        if !request.expected_terminal_id.is_missing() {
            self.require_capability_field("attach-surface", "attach-identity-v1")?;
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
        if request.end_terminals.is_some() {
            self.require_protocol_field("close-pane", 12)?;
            self.require_capability_field("close-pane", "batch-close-v1")?;
        }
        self.execute(&CLOSE_PANE_METADATA, &request)
    }

    pub fn close_provider_managed_workspace(&mut self, request: CloseProviderManagedWorkspaceRequest) -> Result<CloseProviderManagedWorkspaceResult> {
        self.execute(&CLOSE_PROVIDER_MANAGED_WORKSPACE_METADATA, &request)
    }

    pub fn close_screen(&mut self, request: CloseScreenRequest) -> Result<CloseScreenResult> {
        if request.end_terminals.is_some() {
            self.require_protocol_field("close-screen", 12)?;
            self.require_capability_field("close-screen", "batch-close-v1")?;
        }
        self.execute(&CLOSE_SCREEN_METADATA, &request)
    }

    pub fn close_screen_group(&mut self, request: CloseScreenGroupRequest) -> Result<CloseScreenGroupResult> {
        self.execute(&CLOSE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn close_surface(&mut self, request: CloseSurfaceRequest) -> Result<CloseSurfaceResult> {
        self.execute(&CLOSE_SURFACE_METADATA, &request)
    }

    pub fn close_tab_group(&mut self, request: CloseTabGroupRequest) -> Result<CloseTabGroupResult> {
        if request.end_terminals.is_some() {
            self.require_protocol_field("close-tab-group", 12)?;
            self.require_capability_field("close-tab-group", "batch-close-v1")?;
        }
        self.execute(&CLOSE_TAB_GROUP_METADATA, &request)
    }

    pub fn close_tabs(&mut self, request: CloseTabsRequest) -> Result<CloseTabsResult> {
        self.execute(&CLOSE_TABS_METADATA, &request)
    }

    pub fn close_terminal(&mut self, request: CloseTerminalRequest) -> Result<T::CloseTerminalResult> {
        self.execute(&CLOSE_TERMINAL_METADATA, &request)
    }

    pub fn close_workspace(&mut self, request: CloseWorkspaceRequest) -> Result<CloseWorkspaceResult> {
        if request.end_terminals.is_some() {
            self.require_protocol_field("close-workspace", 12)?;
            self.require_capability_field("close-workspace", "batch-close-v1")?;
        }
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

    pub fn create_bookmark(&mut self, request: CreateBookmarkRequest) -> Result<CreateBookmarkResult> {
        self.execute(&CREATE_BOOKMARK_METADATA, &request)
    }

    pub fn create_browser_profile(&mut self, request: CreateBrowserProfileRequest) -> Result<CreateBrowserProfileResult> {
        self.execute(&CREATE_BROWSER_PROFILE_METADATA, &request)
    }

    pub fn create_personal_group(&mut self, request: CreatePersonalGroupRequest) -> Result<CreatePersonalGroupResult> {
        self.execute(&CREATE_PERSONAL_GROUP_METADATA, &request)
    }

    pub fn create_profile(&mut self, request: CreateProfileRequest) -> Result<CreateProfileResult> {
        self.execute(&CREATE_PROFILE_METADATA, &request)
    }

    pub fn create_screen_group(&mut self, request: CreateScreenGroupRequest) -> Result<CreateScreenGroupResult> {
        self.execute(&CREATE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn create_surface_with_receipt(&mut self, request: CreateSurfaceWithReceiptRequest) -> Result<CreateSurfaceWithReceiptResult> {
        if !request.idempotency_key.is_missing() {
            self.require_capability_field("create-surface-with-receipt", "creation-attempt-keys-v1")?;
        }
        self.execute(&CREATE_SURFACE_WITH_RECEIPT_METADATA, &request)
    }

    pub fn create_tab_group(&mut self, request: CreateTabGroupRequest) -> Result<CreateTabGroupResult> {
        self.execute(&CREATE_TAB_GROUP_METADATA, &request)
    }

    pub fn create_terminal(&mut self, request: CreateTerminalRequest) -> Result<CreateTerminalResult> {
        if request.detached.is_some() {
            self.require_protocol_field("create-terminal", 12)?;
            self.require_capability_field("create-terminal", "detached-terminals-v1")?;
        }
        if !request.env.is_missing() {
            self.require_protocol_field("create-terminal", 12)?;
            self.require_capability_field("create-terminal", "terminal-env-v1")?;
        }
        if request.keep.is_some() {
            self.require_protocol_field("create-terminal", 12)?;
            self.require_capability_field("create-terminal", "terminal-reap-v1")?;
        }
        if !request.shell_args.is_missing() {
            self.require_protocol_field("create-terminal", 12)?;
            self.require_capability_field("create-terminal", "terminal-shell-args-v1")?;
        }
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("create-terminal", 9)?;
        }
        self.execute(&CREATE_TERMINAL_METADATA, &request)
    }

    pub fn create_workspace(&mut self, request: CreateWorkspaceRequest) -> Result<CreateWorkspaceResult> {
        self.execute(&CREATE_WORKSPACE_METADATA, &request)
    }

    pub fn create_workspace_group(&mut self, request: CreateWorkspaceGroupRequest) -> Result<CreateWorkspaceGroupResult> {
        self.execute(&CREATE_WORKSPACE_GROUP_METADATA, &request)
    }

    pub fn delete_bookmark(&mut self, request: DeleteBookmarkRequest) -> Result<DeleteBookmarkResult> {
        self.execute(&DELETE_BOOKMARK_METADATA, &request)
    }

    pub fn delete_browser_profile(&mut self, request: DeleteBrowserProfileRequest) -> Result<DeleteBrowserProfileResult> {
        self.execute(&DELETE_BROWSER_PROFILE_METADATA, &request)
    }

    pub fn delete_personal_group(&mut self, request: DeletePersonalGroupRequest) -> Result<DeletePersonalGroupResult> {
        self.execute(&DELETE_PERSONAL_GROUP_METADATA, &request)
    }

    pub fn delete_profile(&mut self, request: DeleteProfileRequest) -> Result<DeleteProfileResult> {
        self.execute(&DELETE_PROFILE_METADATA, &request)
    }

    pub fn delete_saved_screen_group(&mut self, request: DeleteSavedScreenGroupRequest) -> Result<DeleteSavedScreenGroupResult> {
        self.execute(&DELETE_SAVED_SCREEN_GROUP_METADATA, &request)
    }

    pub fn delete_saved_tab_group(&mut self, request: DeleteSavedTabGroupRequest) -> Result<DeleteSavedTabGroupResult> {
        self.execute(&DELETE_SAVED_TAB_GROUP_METADATA, &request)
    }

    pub fn delete_workspace_group(&mut self, request: DeleteWorkspaceGroupRequest) -> Result<DeleteWorkspaceGroupResult> {
        self.execute(&DELETE_WORKSPACE_GROUP_METADATA, &request)
    }

    pub fn detach_attached_view(&mut self, request: DetachAttachedViewRequest) -> Result<DetachAttachedViewResult> {
        if !request.view.is_missing() {
            self.require_protocol_field("detach-attached-view", 12)?;
            self.require_capability_field("detach-attached-view", "shared-sizing-v1")?;
        }
        self.execute(&DETACH_ATTACHED_VIEW_METADATA, &request)
    }

    pub fn detach_client(&mut self, request: DetachClientRequest) -> Result<DetachClientResult> {
        if !request.by.is_missing() {
            self.require_protocol_field("detach-client", 12)?;
            self.require_capability_field("detach-client", "shared-sizing-v1")?;
        }
        if !request.surface.is_missing() {
            self.require_protocol_field("detach-client", 12)?;
            self.require_capability_field("detach-client", "shared-sizing-v1")?;
        }
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

    pub fn forget_session(&mut self, request: ForgetSessionRequest) -> Result<ForgetSessionResult> {
        self.execute(&FORGET_SESSION_METADATA, &request)
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

    pub fn get_size_state(&mut self, request: GetSizeStateRequest) -> Result<T::GetSizeStateResult> {
        self.execute(&GET_SIZE_STATE_METADATA, &request)
    }

    pub fn identify(&mut self, request: IdentifyRequest) -> Result<T::IdentifyResult> {
        self.execute_identify(&IDENTIFY_METADATA, &request)
    }

    pub fn ids(&mut self, request: IdsRequest) -> Result<T::IdsResult> {
        self.execute(&IDS_METADATA, &request)
    }

    pub fn import_bookmarks(&mut self, request: ImportBookmarksRequest) -> Result<ImportBookmarksResult> {
        self.execute(&IMPORT_BOOKMARKS_METADATA, &request)
    }

    pub fn import_session_organization(&mut self, request: ImportSessionOrganizationRequest) -> Result<ImportSessionOrganizationResult> {
        self.execute(&IMPORT_SESSION_ORGANIZATION_METADATA, &request)
    }

    pub fn journal_frontend_event(&mut self, request: JournalFrontendEventRequest) -> Result<JournalFrontendEventResult> {
        self.execute(&JOURNAL_FRONTEND_EVENT_METADATA, &request)
    }

    pub fn list_agents(&mut self, request: ListAgentsRequest) -> Result<T::ListAgentsResult> {
        self.execute(&LIST_AGENTS_METADATA, &request)
    }

    pub fn list_bookmarks(&mut self, request: ListBookmarksRequest) -> Result<ListBookmarksResult> {
        self.execute(&LIST_BOOKMARKS_METADATA, &request)
    }

    pub fn list_clients(&mut self, request: ListClientsRequest) -> Result<ListClientsResult> {
        self.execute(&LIST_CLIENTS_METADATA, &request)
    }

    pub fn list_notifications(&mut self, request: ListNotificationsRequest) -> Result<ListNotificationsResult> {
        self.execute(&LIST_NOTIFICATIONS_METADATA, &request)
    }

    pub fn list_personal(&mut self, request: ListPersonalRequest) -> Result<ListPersonalResult> {
        self.execute(&LIST_PERSONAL_METADATA, &request)
    }

    pub fn list_saved_screen_groups(&mut self, request: ListSavedScreenGroupsRequest) -> Result<ListSavedScreenGroupsResult> {
        self.execute(&LIST_SAVED_SCREEN_GROUPS_METADATA, &request)
    }

    pub fn list_saved_tab_groups(&mut self, request: ListSavedTabGroupsRequest) -> Result<ListSavedTabGroupsResult> {
        self.execute(&LIST_SAVED_TAB_GROUPS_METADATA, &request)
    }

    pub fn list_tab_groups(&mut self, request: ListTabGroupsRequest) -> Result<ListTabGroupsResult> {
        self.execute(&LIST_TAB_GROUPS_METADATA, &request)
    }

    pub fn list_terminals(&mut self, request: ListTerminalsRequest) -> Result<T::ListTerminalsResult> {
        self.execute(&LIST_TERMINALS_METADATA, &request)
    }

    pub fn list_workspace_groups(&mut self, request: ListWorkspaceGroupsRequest) -> Result<ListWorkspaceGroupsResult> {
        self.execute(&LIST_WORKSPACE_GROUPS_METADATA, &request)
    }

    pub fn list_workspaces(&mut self, request: ListWorkspacesRequest) -> Result<ListWorkspacesResult> {
        self.execute(&LIST_WORKSPACES_METADATA, &request)
    }

    pub fn machine_listening_tcp(&mut self, request: MachineListeningTcpRequest) -> Result<T::MachineListeningTcpResult> {
        self.execute(&MACHINE_LISTENING_TCP_METADATA, &request)
    }

    pub fn machine_usage(&mut self, request: MachineUsageRequest) -> Result<T::MachineUsageResult> {
        self.execute(&MACHINE_USAGE_METADATA, &request)
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

    pub fn move_bookmark(&mut self, request: MoveBookmarkRequest) -> Result<MoveBookmarkResult> {
        self.execute(&MOVE_BOOKMARK_METADATA, &request)
    }

    pub fn move_browser_profile(&mut self, request: MoveBrowserProfileRequest) -> Result<MoveBrowserProfileResult> {
        self.execute(&MOVE_BROWSER_PROFILE_METADATA, &request)
    }

    pub fn move_personal_group(&mut self, request: MovePersonalGroupRequest) -> Result<MovePersonalGroupResult> {
        self.execute(&MOVE_PERSONAL_GROUP_METADATA, &request)
    }

    pub fn move_profile(&mut self, request: MoveProfileRequest) -> Result<MoveProfileResult> {
        self.execute(&MOVE_PROFILE_METADATA, &request)
    }

    pub fn move_screen(&mut self, request: MoveScreenRequest) -> Result<MoveScreenResult> {
        self.execute(&MOVE_SCREEN_METADATA, &request)
    }

    pub fn move_screen_group(&mut self, request: MoveScreenGroupRequest) -> Result<MoveScreenGroupResult> {
        self.execute(&MOVE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn move_tab(&mut self, request: MoveTabRequest) -> Result<MoveTabResult> {
        if !request.transaction.is_missing() {
            self.require_protocol_field("move-tab", 12)?;
            self.require_capability_field("move-tab", "tab-drag-v1")?;
        }
        self.execute(&MOVE_TAB_METADATA, &request)
    }

    pub fn move_tab_group(&mut self, request: MoveTabGroupRequest) -> Result<MoveTabGroupResult> {
        self.execute(&MOVE_TAB_GROUP_METADATA, &request)
    }

    pub fn move_tab_group_to_column(&mut self, request: MoveTabGroupToColumnRequest) -> Result<MoveTabGroupToColumnResult> {
        self.execute(&MOVE_TAB_GROUP_TO_COLUMN_METADATA, &request)
    }

    pub fn move_tab_group_to_new_workspace(&mut self, request: MoveTabGroupToNewWorkspaceRequest) -> Result<MoveTabGroupToNewWorkspaceResult> {
        self.execute(&MOVE_TAB_GROUP_TO_NEW_WORKSPACE_METADATA, &request)
    }

    pub fn move_tab_group_to_split(&mut self, request: MoveTabGroupToSplitRequest) -> Result<MoveTabGroupToSplitResult> {
        self.execute(&MOVE_TAB_GROUP_TO_SPLIT_METADATA, &request)
    }

    pub fn move_tab_to_column(&mut self, request: MoveTabToColumnRequest) -> Result<MoveTabToColumnResult> {
        self.execute(&MOVE_TAB_TO_COLUMN_METADATA, &request)
    }

    pub fn move_tab_to_new_workspace(&mut self, request: MoveTabToNewWorkspaceRequest) -> Result<MoveTabToNewWorkspaceResult> {
        self.execute(&MOVE_TAB_TO_NEW_WORKSPACE_METADATA, &request)
    }

    pub fn move_tab_to_split(&mut self, request: MoveTabToSplitRequest) -> Result<MoveTabToSplitResult> {
        self.execute(&MOVE_TAB_TO_SPLIT_METADATA, &request)
    }

    pub fn move_tab_to_workspace(&mut self, request: MoveTabToWorkspaceRequest) -> Result<MoveTabToWorkspaceResult> {
        if !request.transaction.is_missing() {
            self.require_protocol_field("move-tab-to-workspace", 12)?;
            self.require_capability_field("move-tab-to-workspace", "tab-drag-v1")?;
        }
        self.execute(&MOVE_TAB_TO_WORKSPACE_METADATA, &request)
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

    pub fn move_workspace_group(&mut self, request: MoveWorkspaceGroupRequest) -> Result<MoveWorkspaceGroupResult> {
        self.execute(&MOVE_WORKSPACE_GROUP_METADATA, &request)
    }

    pub fn move_workspace_to_group(&mut self, request: MoveWorkspaceToGroupRequest) -> Result<MoveWorkspaceToGroupResult> {
        self.execute(&MOVE_WORKSPACE_TO_GROUP_METADATA, &request)
    }

    pub fn new_browser_tab(&mut self, request: NewBrowserTabRequest) -> Result<NewBrowserTabResult> {
        self.execute(&NEW_BROWSER_TAB_METADATA, &request)
    }

    pub fn new_frontend_browser_tab(&mut self, request: NewFrontendBrowserTabRequest) -> Result<NewFrontendBrowserTabResult> {
        self.execute(&NEW_FRONTEND_BROWSER_TAB_METADATA, &request)
    }

    pub fn new_pane(&mut self, request: NewPaneRequest) -> Result<NewPaneResult> {
        if !request.cwd.is_missing() {
            self.require_protocol_field("new-pane", 12)?;
            self.require_capability_field("new-pane", "terminal-placement-env-v1")?;
        }
        if !request.env.is_missing() {
            self.require_protocol_field("new-pane", 12)?;
            self.require_capability_field("new-pane", "terminal-placement-env-v1")?;
        }
        if request.keep.is_some() {
            self.require_protocol_field("new-pane", 12)?;
            self.require_capability_field("new-pane", "terminal-reap-v1")?;
        }
        if !request.shell_args.is_missing() {
            self.require_protocol_field("new-pane", 12)?;
            self.require_capability_field("new-pane", "terminal-shell-args-v1")?;
        }
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("new-pane", 12)?;
            self.require_capability_field("new-pane", "terminal-placement-env-v1")?;
        }
        self.execute(&NEW_PANE_METADATA, &request)
    }

    pub fn new_pane_right(&mut self, request: NewPaneRightRequest) -> Result<NewPaneRightResult> {
        if !request.cwd.is_missing() {
            self.require_protocol_field("new-pane-right", 12)?;
            self.require_capability_field("new-pane-right", "terminal-placement-env-v1")?;
        }
        if !request.env.is_missing() {
            self.require_protocol_field("new-pane-right", 12)?;
            self.require_capability_field("new-pane-right", "terminal-placement-env-v1")?;
        }
        if request.keep.is_some() {
            self.require_protocol_field("new-pane-right", 12)?;
            self.require_capability_field("new-pane-right", "terminal-reap-v1")?;
        }
        if !request.shell_args.is_missing() {
            self.require_protocol_field("new-pane-right", 12)?;
            self.require_capability_field("new-pane-right", "terminal-shell-args-v1")?;
        }
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("new-pane-right", 12)?;
            self.require_capability_field("new-pane-right", "terminal-placement-env-v1")?;
        }
        self.execute(&NEW_PANE_RIGHT_METADATA, &request)
    }

    pub fn new_remote_terminal_tab(&mut self, request: NewRemoteTerminalTabRequest) -> Result<NewRemoteTerminalTabResult> {
        self.execute(&NEW_REMOTE_TERMINAL_TAB_METADATA, &request)
    }

    pub fn new_screen(&mut self, request: NewScreenRequest) -> Result<NewScreenResult> {
        self.execute(&NEW_SCREEN_METADATA, &request)
    }

    pub fn new_tab(&mut self, request: NewTabRequest) -> Result<NewTabResult> {
        if !request.env.is_missing() {
            self.require_protocol_field("new-tab", 12)?;
            self.require_capability_field("new-tab", "terminal-env-v1")?;
        }
        if request.keep.is_some() {
            self.require_protocol_field("new-tab", 12)?;
            self.require_capability_field("new-tab", "terminal-reap-v1")?;
        }
        if !request.shell_args.is_missing() {
            self.require_protocol_field("new-tab", 12)?;
            self.require_capability_field("new-tab", "terminal-shell-args-v1")?;
        }
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("new-tab", 12)?;
            self.require_capability_field("new-tab", "terminal-placement-env-v1")?;
        }
        self.execute(&NEW_TAB_METADATA, &request)
    }

    pub fn new_workspace(&mut self, request: NewWorkspaceRequest) -> Result<NewWorkspaceResult> {
        self.execute(&NEW_WORKSPACE_METADATA, &request)
    }

    pub fn note_size_activity(&mut self, request: NoteSizeActivityRequest) -> Result<T::NoteSizeActivityResult> {
        self.execute(&NOTE_SIZE_ACTIVITY_METADATA, &request)
    }

    pub fn notify(&mut self, request: NotifyRequest) -> Result<T::NotifyResult> {
        if !request.source.is_missing() {
            self.require_protocol_field("notify", 12)?;
            self.require_capability_field("notify", "notification-source-v1")?;
        }
        self.execute(&NOTIFY_METADATA, &request)
    }

    pub fn pairing_response(&mut self, request: PairingResponseRequest) -> Result<PairingResponseResult> {
        self.execute(&PAIRING_RESPONSE_METADATA, &request)
    }

    pub fn pane_neighbor(&mut self, request: PaneNeighborRequest) -> Result<T::PaneNeighborResult> {
        self.execute(&PANE_NEIGHBOR_METADATA, &request)
    }

    pub fn paste_image(&mut self, request: PasteImageRequest) -> Result<PasteImageResult> {
        self.execute(&PASTE_IMAGE_METADATA, &request)
    }

    pub fn pin_workspace(&mut self, request: PinWorkspaceRequest) -> Result<PinWorkspaceResult> {
        self.execute(&PIN_WORKSPACE_METADATA, &request)
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

    pub fn put_session(&mut self, request: PutSessionRequest) -> Result<PutSessionResult> {
        self.execute(&PUT_SESSION_METADATA, &request)
    }

    pub fn read_screen(&mut self, request: ReadScreenRequest) -> Result<T::ReadScreenResult> {
        self.execute(&READ_SCREEN_METADATA, &request)
    }

    pub fn read_scrollback(&mut self, request: ReadScrollbackRequest) -> Result<T::ReadScrollbackResult> {
        self.execute(&READ_SCROLLBACK_METADATA, &request)
    }

    pub fn reattach_view(&mut self, request: ReattachViewRequest) -> Result<T::ReattachViewResult> {
        self.execute(&REATTACH_VIEW_METADATA, &request)
    }

    pub fn register_browser_provider(&mut self, request: RegisterBrowserProviderRequest) -> Result<RegisterBrowserProviderResult> {
        self.execute(&REGISTER_BROWSER_PROVIDER_METADATA, &request)
    }

    pub fn release_attached_view_size(&mut self, request: ReleaseAttachedViewSizeRequest) -> Result<ReleaseAttachedViewSizeResult> {
        if !request.view.is_missing() {
            self.require_protocol_field("release-attached-view-size", 12)?;
            self.require_capability_field("release-attached-view-size", "shared-sizing-v1")?;
        }
        self.execute(&RELEASE_ATTACHED_VIEW_SIZE_METADATA, &request)
    }

    pub fn release_surface_size(&mut self, request: ReleaseSurfaceSizeRequest) -> Result<ReleaseSurfaceSizeResult> {
        self.execute(&RELEASE_SURFACE_SIZE_METADATA, &request)
    }

    pub fn reload_config(&mut self, request: ReloadConfigRequest) -> Result<ReloadConfigResult> {
        self.execute(&RELOAD_CONFIG_METADATA, &request)
    }

    pub fn remote_terminal_snapshot(&mut self, request: RemoteTerminalSnapshotRequest) -> Result<RemoteTerminalSnapshotResult> {
        self.execute(&REMOTE_TERMINAL_SNAPSHOT_METADATA, &request)
    }

    pub fn remove_screens_from_screen_group(&mut self, request: RemoveScreensFromScreenGroupRequest) -> Result<RemoveScreensFromScreenGroupResult> {
        self.execute(&REMOVE_SCREENS_FROM_SCREEN_GROUP_METADATA, &request)
    }

    pub fn remove_tabs_from_tab_group(&mut self, request: RemoveTabsFromTabGroupRequest) -> Result<RemoveTabsFromTabGroupResult> {
        self.execute(&REMOVE_TABS_FROM_TAB_GROUP_METADATA, &request)
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

    pub fn reopen_saved_screen_group(&mut self, request: ReopenSavedScreenGroupRequest) -> Result<ReopenSavedScreenGroupResult> {
        self.execute(&REOPEN_SAVED_SCREEN_GROUP_METADATA, &request)
    }

    pub fn reopen_saved_tab_group(&mut self, request: ReopenSavedTabGroupRequest) -> Result<ReopenSavedTabGroupResult> {
        self.execute(&REOPEN_SAVED_TAB_GROUP_METADATA, &request)
    }

    pub fn report_agent(&mut self, request: ReportAgentRequest) -> Result<T::ReportAgentResult> {
        self.execute(&REPORT_AGENT_METADATA, &request)
    }

    pub fn report_focus(&mut self, request: ReportFocusRequest) -> Result<ReportFocusResult> {
        self.execute(&REPORT_FOCUS_METADATA, &request)
    }

    pub fn resize_attached_view(&mut self, request: ResizeAttachedViewRequest) -> Result<ResizeAttachedViewResult> {
        if !request.identity.is_missing() {
            self.require_protocol_field("resize-attached-view", 12)?;
            self.require_capability_field("resize-attached-view", "shared-sizing-v1")?;
        }
        if !request.view.is_missing() {
            self.require_protocol_field("resize-attached-view", 12)?;
            self.require_capability_field("resize-attached-view", "shared-sizing-v1")?;
        }
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

    pub fn save_screen_group(&mut self, request: SaveScreenGroupRequest) -> Result<SaveScreenGroupResult> {
        self.execute(&SAVE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn save_tab_group(&mut self, request: SaveTabGroupRequest) -> Result<SaveTabGroupResult> {
        self.execute(&SAVE_TAB_GROUP_METADATA, &request)
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

    pub fn server_stats(&mut self, request: ServerStatsRequest) -> Result<T::ServerStatsResult> {
        self.execute(&SERVER_STATS_METADATA, &request)
    }

    pub fn set_cell_pixels(&mut self, request: SetCellPixelsRequest) -> Result<T::SetCellPixelsResult> {
        self.execute(&SET_CELL_PIXELS_METADATA, &request)
    }

    pub fn set_client_info(&mut self, request: SetClientInfoRequest) -> Result<SetClientInfoResult> {
        if !request.device_id.is_missing() {
            self.require_protocol_field("set-client-info", 12)?;
            self.require_capability_field("set-client-info", "shared-sizing-v1")?;
        }
        if !request.device_kind.is_missing() {
            self.require_protocol_field("set-client-info", 12)?;
            self.require_capability_field("set-client-info", "shared-sizing-v1")?;
        }
        if !request.device_name.is_missing() {
            self.require_protocol_field("set-client-info", 12)?;
            self.require_capability_field("set-client-info", "shared-sizing-v1")?;
        }
        if !request.display_name.is_missing() {
            self.require_protocol_field("set-client-info", 12)?;
            self.require_capability_field("set-client-info", "shared-sizing-v1")?;
        }
        if !request.user_id.is_missing() {
            self.require_protocol_field("set-client-info", 12)?;
            self.require_capability_field("set-client-info", "shared-sizing-v1")?;
        }
        self.execute(&SET_CLIENT_INFO_METADATA, &request)
    }

    pub fn set_client_sizing(&mut self, request: SetClientSizingRequest) -> Result<SetClientSizingResult> {
        self.execute(&SET_CLIENT_SIZING_METADATA, &request)
    }

    pub fn set_column_sticky(&mut self, request: SetColumnStickyRequest) -> Result<SetColumnStickyResult> {
        self.execute(&SET_COLUMN_STICKY_METADATA, &request)
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

    pub fn set_personal_terminal(&mut self, request: SetPersonalTerminalRequest) -> Result<SetPersonalTerminalResult> {
        self.execute(&SET_PERSONAL_TERMINAL_METADATA, &request)
    }

    pub fn set_personal_workspace(&mut self, request: SetPersonalWorkspaceRequest) -> Result<SetPersonalWorkspaceResult> {
        self.execute(&SET_PERSONAL_WORKSPACE_METADATA, &request)
    }

    pub fn set_profile_follows(&mut self, request: SetProfileFollowsRequest) -> Result<SetProfileFollowsResult> {
        self.execute(&SET_PROFILE_FOLLOWS_METADATA, &request)
    }

    pub fn set_ratio(&mut self, request: SetRatioRequest) -> Result<SetRatioResult> {
        self.execute(&SET_RATIO_METADATA, &request)
    }

    pub fn set_screen_metadata(&mut self, request: SetScreenMetadataRequest) -> Result<SetScreenMetadataResult> {
        self.execute(&SET_SCREEN_METADATA_METADATA, &request)
    }

    pub fn set_screen_pinned(&mut self, request: SetScreenPinnedRequest) -> Result<SetScreenPinnedResult> {
        self.execute(&SET_SCREEN_PINNED_METADATA, &request)
    }

    pub fn set_size_counts(&mut self, request: SetSizeCountsRequest) -> Result<T::SetSizeCountsResult> {
        self.execute(&SET_SIZE_COUNTS_METADATA, &request)
    }

    pub fn set_size_policy(&mut self, request: SetSizePolicyRequest) -> Result<T::SetSizePolicyResult> {
        self.execute(&SET_SIZE_POLICY_METADATA, &request)
    }

    pub fn set_split_ratio(&mut self, request: SetSplitRatioRequest) -> Result<SetSplitRatioResult> {
        if !request.transaction.is_missing() {
            self.require_protocol_field("set-split-ratio", 9)?;
            self.require_capability_field("set-split-ratio", "layout-undo-v1")?;
        }
        self.execute(&SET_SPLIT_RATIO_METADATA, &request)
    }

    pub fn set_tab_pinned(&mut self, request: SetTabPinnedRequest) -> Result<SetTabPinnedResult> {
        self.execute(&SET_TAB_PINNED_METADATA, &request)
    }

    pub fn set_terminal_command_history(&mut self, request: SetTerminalCommandHistoryRequest) -> Result<SetTerminalCommandHistoryResult> {
        self.execute(&SET_TERMINAL_COMMAND_HISTORY_METADATA, &request)
    }

    pub fn set_terminal_idle_policy(&mut self, request: SetTerminalIdlePolicyRequest) -> Result<T::SetTerminalIdlePolicyResult> {
        self.execute(&SET_TERMINAL_IDLE_POLICY_METADATA, &request)
    }

    pub fn set_terminal_keep(&mut self, request: SetTerminalKeepRequest) -> Result<T::SetTerminalKeepResult> {
        self.execute(&SET_TERMINAL_KEEP_METADATA, &request)
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

    pub fn set_workspace_metadata(&mut self, request: SetWorkspaceMetadataRequest) -> Result<SetWorkspaceMetadataResult> {
        if !request.marked_unread.is_missing() {
            self.require_protocol_field("set-workspace-metadata", 12)?;
            self.require_capability_field("set-workspace-metadata", "notification-mark-unread-v1")?;
        }
        if !request.pinned.is_missing() {
            self.require_protocol_field("set-workspace-metadata", 12)?;
            self.require_capability_field("set-workspace-metadata", "workspace-pin-v1")?;
        }
        self.execute(&SET_WORKSPACE_METADATA_METADATA, &request)
    }

    pub fn shutdown_daemon(&mut self, request: ShutdownDaemonRequest) -> Result<T::ShutdownDaemonResult> {
        if request.end_terminals.is_some() {
            self.require_protocol_field("shutdown-daemon", 12)?;
            self.require_capability_field("shutdown-daemon", "terminal-reap-v1")?;
        }
        if request.force.is_some() {
            self.require_protocol_field("shutdown-daemon", 10)?;
            self.require_capability_field("shutdown-daemon", "daemon-handoff-force-v1")?;
        }
        if request.keep_layout.is_some() {
            self.require_protocol_field("shutdown-daemon", 12)?;
            self.require_capability_field("shutdown-daemon", "end-terminals-keep-layout-v1")?;
        }
        self.execute(&SHUTDOWN_DAEMON_METADATA, &request)
    }

    pub fn sidebar_plugin(&mut self, request: SidebarPluginRequest) -> Result<T::SidebarPluginResult> {
        self.execute(&SIDEBAR_PLUGIN_METADATA, &request)
    }

    pub fn split(&mut self, request: SplitRequest) -> Result<SplitResult> {
        if !request.cwd.is_missing() {
            self.require_protocol_field("split", 12)?;
            self.require_capability_field("split", "terminal-env-v1")?;
        }
        if !request.env.is_missing() {
            self.require_protocol_field("split", 12)?;
            self.require_capability_field("split", "terminal-env-v1")?;
        }
        if request.keep.is_some() {
            self.require_protocol_field("split", 12)?;
            self.require_capability_field("split", "terminal-reap-v1")?;
        }
        if !request.shell_args.is_missing() {
            self.require_protocol_field("split", 12)?;
            self.require_capability_field("split", "terminal-shell-args-v1")?;
        }
        if !request.terminal_id.is_missing() {
            self.require_protocol_field("split", 12)?;
            self.require_capability_field("split", "terminal-placement-env-v1")?;
        }
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

    pub fn terminal_resources(&mut self, request: TerminalResourcesRequest) -> Result<T::TerminalResourcesResult> {
        self.execute(&TERMINAL_RESOURCES_METADATA, &request)
    }

    pub fn undo_layout(&mut self, request: UndoLayoutRequest) -> Result<UndoLayoutResult> {
        self.execute(&UNDO_LAYOUT_METADATA, &request)
    }

    pub fn ungroup_screen_group(&mut self, request: UngroupScreenGroupRequest) -> Result<UngroupScreenGroupResult> {
        self.execute(&UNGROUP_SCREEN_GROUP_METADATA, &request)
    }

    pub fn ungroup_tab_group(&mut self, request: UngroupTabGroupRequest) -> Result<UngroupTabGroupResult> {
        self.execute(&UNGROUP_TAB_GROUP_METADATA, &request)
    }

    pub fn unpin_workspace(&mut self, request: UnpinWorkspaceRequest) -> Result<UnpinWorkspaceResult> {
        self.execute(&UNPIN_WORKSPACE_METADATA, &request)
    }

    pub fn unregister_browser_provider(&mut self, request: UnregisterBrowserProviderRequest) -> Result<UnregisterBrowserProviderResult> {
        self.execute(&UNREGISTER_BROWSER_PROVIDER_METADATA, &request)
    }

    pub fn unsave_screen_group(&mut self, request: UnsaveScreenGroupRequest) -> Result<UnsaveScreenGroupResult> {
        self.execute(&UNSAVE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn unsave_tab_group(&mut self, request: UnsaveTabGroupRequest) -> Result<UnsaveTabGroupResult> {
        self.execute(&UNSAVE_TAB_GROUP_METADATA, &request)
    }

    pub fn update_bookmark(&mut self, request: UpdateBookmarkRequest) -> Result<UpdateBookmarkResult> {
        self.execute(&UPDATE_BOOKMARK_METADATA, &request)
    }

    pub fn update_browser_profile(&mut self, request: UpdateBrowserProfileRequest) -> Result<UpdateBrowserProfileResult> {
        self.execute(&UPDATE_BROWSER_PROFILE_METADATA, &request)
    }

    pub fn update_frontend_browser_tab(&mut self, request: UpdateFrontendBrowserTabRequest) -> Result<UpdateFrontendBrowserTabResult> {
        self.execute(&UPDATE_FRONTEND_BROWSER_TAB_METADATA, &request)
    }

    pub fn update_personal_group(&mut self, request: UpdatePersonalGroupRequest) -> Result<UpdatePersonalGroupResult> {
        self.execute(&UPDATE_PERSONAL_GROUP_METADATA, &request)
    }

    pub fn update_profile(&mut self, request: UpdateProfileRequest) -> Result<UpdateProfileResult> {
        self.execute(&UPDATE_PROFILE_METADATA, &request)
    }

    pub fn update_remote_terminal_tab(&mut self, request: UpdateRemoteTerminalTabRequest) -> Result<UpdateRemoteTerminalTabResult> {
        self.execute(&UPDATE_REMOTE_TERMINAL_TAB_METADATA, &request)
    }

    pub fn update_screen_group(&mut self, request: UpdateScreenGroupRequest) -> Result<UpdateScreenGroupResult> {
        self.execute(&UPDATE_SCREEN_GROUP_METADATA, &request)
    }

    pub fn update_tab_group(&mut self, request: UpdateTabGroupRequest) -> Result<UpdateTabGroupResult> {
        self.execute(&UPDATE_TAB_GROUP_METADATA, &request)
    }

    pub fn update_workspace_group(&mut self, request: UpdateWorkspaceGroupRequest) -> Result<UpdateWorkspaceGroupResult> {
        self.execute(&UPDATE_WORKSPACE_GROUP_METADATA, &request)
    }

    pub fn url_open(&mut self, request: UrlOpenRequest) -> Result<UrlOpenResult> {
        self.execute(&URL_OPEN_METADATA, &request)
    }

    pub fn url_open_claim(&mut self, request: UrlOpenClaimRequest) -> Result<UrlOpenClaimResult> {
        self.execute(&URL_OPEN_CLAIM_METADATA, &request)
    }

    pub fn url_open_result(&mut self, request: UrlOpenResultRequest) -> Result<UrlOpenResultResult> {
        self.execute(&URL_OPEN_RESULT_METADATA, &request)
    }

    pub fn url_open_subscribe(&mut self, request: UrlOpenSubscribeRequest) -> Result<CmuxStream> {
        self.execute_stream(&URL_OPEN_SUBSCRIBE_METADATA, &request)
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

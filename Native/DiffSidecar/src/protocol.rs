use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::PROTOCOL_VERSION;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffRequest {
    pub id: String,
    pub version: u32,
    #[serde(flatten)]
    pub command: DiffCommand,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "method", content = "params", rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffCommand {
    ProtocolHandshake,
    SessionOpen(OpenSessionRequest),
    SessionClose(SessionRequest),
    BranchList(BranchListRequest),
    BranchChange(BranchChangeRequest),
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct OpenSessionRequest {
    pub source: DiffSource,
    pub capability_token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub session_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
#[ts(export_to = "protocol.ts")]
pub enum DiffSource {
    Patch {
        path: String,
    },
    Unstaged {
        repo_root: String,
    },
    Staged {
        repo_root: String,
    },
    Branch {
        repo_root: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        base_ref: Option<String>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct SessionRequest {
    pub session_id: String,
    pub capability_token: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchListRequest {
    pub repo_root: String,
    pub capability_token: String,
    pub selected_base: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchChangeRequest {
    pub group_id: String,
    pub repo_root: String,
    pub base_ref: String,
    pub capability_token: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchListResult {
    pub groups: Vec<BranchPickerGroup>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchPickerGroup {
    pub id: String,
    pub label: String,
    pub rows: Vec<BranchPickerRow>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchPickerRow {
    pub r#ref: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub secondary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub confidence: Option<BranchPickerConfidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub current: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub worktree_dir: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum BranchPickerConfidence {
    High,
    Low,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffResourceRef {
    pub id: String,
    pub media_type: String,
    pub byte_length: Option<u64>,
    pub revision: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffTransportConfig {
    pub kind: DiffTransportKind,
    pub endpoint: String,
    pub protocol_version: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffTransportKind {
    Fetch,
    WebSocket,
    WebKit,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffResponse {
    pub id: String,
    pub version: u32,
    pub result: Option<DiffResult>,
    pub error: Option<DiffProtocolError>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffResult {
    Handshake(HandshakeResult),
    SessionOpened(SessionOpened),
    SessionClosed,
    Branches(BranchListResult),
    Navigation(NavigationResult),
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct HandshakeResult {
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct SessionOpened {
    pub session_id: String,
    pub patch: DiffResourceRef,
    pub source: DiffSource,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct NavigationResult {
    pub url: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct DiffProtocolError {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
#[ts(export_to = "protocol.ts")]
pub enum DiffEvent {
    SessionStatus {
        session_id: String,
        status: DiffSessionStatus,
    },
    PatchReady {
        session_id: String,
        patch: DiffResourceRef,
    },
    SessionFailed {
        session_id: String,
        error: DiffProtocolError,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum DiffSessionStatus {
    Opening,
    Ready,
    Closed,
}

impl DiffResponse {
    #[must_use]
    pub fn success(id: String, result: DiffResult) -> Self {
        Self {
            id,
            version: PROTOCOL_VERSION,
            result: Some(result),
            error: None,
        }
    }

    #[must_use]
    pub fn failure(id: String, code: &str, message: &str) -> Self {
        Self {
            id,
            version: PROTOCOL_VERSION,
            result: None,
            error: Some(DiffProtocolError {
                code: code.to_owned(),
                message: message.to_owned(),
            }),
        }
    }
}

#[must_use]
pub fn handshake(id: String) -> DiffResponse {
    let capabilities = vec![
        "resource.stream".to_owned(),
        "transport.webkit".to_owned(),
        "transport.stdio".to_owned(),
    ];
    #[cfg(feature = "http-server")]
    let capabilities = {
        let mut capabilities = capabilities;
        capabilities.extend([
            "transport.fetch".to_owned(),
            "transport.websocket".to_owned(),
        ]);
        capabilities
    };
    DiffResponse::success(
        id,
        DiffResult::Handshake(HandshakeResult {
            protocol_version: PROTOCOL_VERSION,
            capabilities,
        }),
    )
}

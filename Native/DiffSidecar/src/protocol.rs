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
    FileContents(FileContentsRequest),
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
    /// The viewer's Hide white space: diff with `--ignore-all-space`. Only
    /// the git-backed sources (unstaged, staged, branch) honor it; a `patch`
    /// source opens as it is. `SessionOpened.ignoreWhitespace` says which.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub ignore_whitespace: Option<bool>,
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
    /// As `OpenSessionRequest.ignoreWhitespace`, for the new branch session.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub ignore_whitespace: Option<bool>,
}

/// One file's two sides in a git-backed session, so the viewer can show its
/// unchanged lines (Load full files) and preview it (Rich preview). Old and new
/// are the sides the session's patch compares: unstaged is the index against
/// the work tree, staged is HEAD against the index, a branch is its base
/// commit against the work tree. Only a path the session's patch names may be
/// read. A `patch` session (a chat's turn) has no sides.
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct FileContentsRequest {
    pub session_id: String,
    pub capability_token: String,
    /// The file's path in the repository, as the patch names its new side.
    pub path: String,
    /// A rename's or copy's old path: the old side is read from it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub previous_path: Option<String>,
    /// `text` (the default) or `base64`, for a binary file such as an image.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub encoding: Option<FileContentsEncoding>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub enum FileContentsEncoding {
    /// UTF-8 text; bytes that are not UTF-8 read as U+FFFD.
    #[default]
    Text,
    Base64,
}

/// `fileContents`'s answer. A side is missing when the file does not exist on
/// it (an added file has no old side, a deleted one no new side). When either
/// side is over the size limit, `tooLarge` is true and neither side is sent.
#[derive(Clone, Debug, Default, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct FileContentsResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub old: Option<FileSide>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub new: Option<FileSide>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub too_large: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct FileSide {
    pub contents: String,
    pub encoding: FileContentsEncoding,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(rename_all = "camelCase")]
#[ts(export_to = "protocol.ts")]
pub struct BranchListResult {
    pub groups: Vec<BranchPickerGroup>,
    /// Present and true when the repository has more branches than the
    /// picker lists.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub truncated: Option<bool>,
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
    /// The cmux-next page bridge: the page sends each request as a
    /// `cmux.diff.*` call over `cmuxPage`, the host runs the sidecar's `rpc`
    /// mode with `--resource-scheme page`, and events arrive on the
    /// `cmux.diff.events` subscription. `endpoint` names the page provider
    /// (`cmux.diff`). Patch resources use [`PAGE_PATCH_URL_PREFIX`].
    Page,
}

/// Patch resources minted for the page transport start with this prefix,
/// followed by the capability token and the manifest request path. The page
/// host's dynamic scheme handler resolves them against the token's manifest.
pub const PAGE_PATCH_URL_PREFIX: &str = "cmux-page://cmux.diff/__patch/";

/// The handshake capability of a sidecar that honors
/// `OpenSessionRequest.ignoreWhitespace` (and `BranchChangeRequest`'s) for
/// the git-backed sources. A `patch` source cannot: its patch is fixed.
pub const IGNORE_WHITESPACE_CAPABILITY: &str = "session.ignoreWhitespace";

/// The handshake capability of a sidecar that answers `fileContents` for the
/// git-backed sessions it opened.
pub const FILE_CONTENTS_CAPABILITY: &str = "session.fileContents";

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
    FileContents(FileContentsResult),
    /// Classic page navigation. No command returns it since `branchChange`
    /// opens a session instead; kept so existing clients still type-check.
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
    /// Changed paths the repository marks generated (`.gitattributes`
    /// `linguist-generated` or `-diff`); the viewer collapses them by default.
    #[serde(default)]
    pub generated_paths: Vec<String>,
    /// True when the patch was made with white space changes ignored
    /// (`OpenSessionRequest.ignoreWhitespace` on a git-backed source). Its
    /// hunks then do not match the files' real diff, so the viewer must not
    /// stage, unstage or revert one hunk of it.
    #[serde(default)]
    pub ignore_whitespace: bool,
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
        "transport.page".to_owned(),
        "transport.stdio".to_owned(),
        IGNORE_WHITESPACE_CAPABILITY.to_owned(),
        FILE_CONTENTS_CAPABILITY.to_owned(),
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

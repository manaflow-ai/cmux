//! The conversation owner's side (home.md section 2): the port the brain
//! writes through, and the link that connects with cmux-sdk, finds or
//! creates the Chief conversation exactly as mux/host does, binds as
//! `agent_mux` (or the Chief's own participant, `membership`), subscribes,
//! and reconnects after a loss.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux::raw::{
    Client, ClientConfig, ConversationAttachmentReadRequest, ConversationAttachmentUploadRequest,
    ConversationAttachmentUploadResult, ConversationBindRequest, ConversationCreateRequest,
    ConversationDraftRequest, ConversationHistoryRequest, ConversationListRequest,
    ConversationLivePublishRequest, ConversationOpRequest, ConversationRunAppendRequest,
    ConversationSnapshotRequest, ConversationTypingRequest, Error as SdkError, Event, Nullable,
    Optional, SubscribeRequest, SubscribeRequestTreeEvents,
};
use cmux_chief::rules::{
    AGENT_MUX, CHIEF_CONVERSATION_TITLE, CHIEF_DISPLAY_NAME, DEFAULT_CONVERSATION_KEY,
    MUX_SESSION_NAME, USER_LOCAL,
};
use cmux_conversation::{
    AgentClass, Change, DerivedImage, Message, Op, Participant, ParticipantKind, Summary,
};
use serde_json::Value;

pub const CAPABILITY: &str = "local-conversations-v1";

/// A failed write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpError {
    /// The owner refused it; the text holds the reason code (`agent_rate`, ...).
    Rejected(String),
    /// The connection failed; the write may or may not have happened.
    Transport(String),
}

impl std::fmt::Display for OpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OpError::Rejected(r) => write!(f, "rejected: {r}"),
            OpError::Transport(e) => write!(f, "transport: {e}"),
        }
    }
}

/// Most bytes the owner sends in one `conversation-attachment-read`, and
/// takes in one `conversation-attachment-upload` chunk.
pub const ATTACHMENT_CHUNK_BYTES: u64 = 4 * 1024 * 1024;

/// The conversation operations the brain needs, on a connection bound as `agent_mux`.
pub trait ConversationPort: Send {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError>;
    fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Vec<Message>, OpError>;
    /// Commits `op` as `agent_mux`; returns the change on success.
    fn op(&mut self, conversation: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError>;
    fn typing(&mut self, conversation: &str, on: bool) -> Result<(), OpError>;
    /// Publishes a draft of the running turn's reply (`conversation.draft`,
    /// never stored). No default: a silent no-op once hid that the local
    /// port never sent one; a port without drafts says so with an error.
    fn draft(&mut self, conversation: &str, draft: &crate::draft::Draft) -> Result<(), OpError>;
    /// Appends to the running turn's run record (`conversation-run-append`,
    /// `conversation-runs-v1`). Display only, like drafts: a port without
    /// runs says so with an error and the turn goes on.
    fn run_append(
        &mut self,
        _conversation: &str,
        _run: Value,
        _steps: Vec<Value>,
    ) -> Result<(), OpError> {
        Err(OpError::Rejected("runs_unsupported".into()))
    }
    /// Sends one live frame of the running turn's run (`conversation-live-publish`,
    /// `chief-live-v1`): the reply's text as it streams and a "working on"
    /// line. Display only and never stored: a port without it says so with an
    /// error and the turn goes on.
    fn live_publish(&mut self, _conversation: &str, _frame: Value) -> Result<(), OpError> {
        Err(OpError::Rejected("live_unsupported".into()))
    }
    /// Uploads a picture a run step shows as an attachment record of
    /// `conversation` this connection's agent may name (one chunk, at most
    /// 4 MiB; the same steps as a link preview's picture).
    fn upload_run_image(
        &mut self,
        conversation: &str,
        bytes: &[u8],
        mime_type: &str,
        name: &str,
        width: u32,
        height: u32,
    ) -> Result<DerivedImage, OpError> {
        let _ = (conversation, bytes, mime_type, name, width, height);
        Err(OpError::Rejected("attachments_unsupported".into()))
    }
    /// One attachment variant (`original`, `preview`, `poster`) of `hash`,
    /// all `bytes` of it, base64 (`local-attachments-v1`). The owner sends at
    /// most [`ATTACHMENT_CHUNK_BYTES`] a read, so a larger file takes several
    /// reads; an error when the owner ends before `bytes`.
    fn attachment(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
    ) -> Result<String, OpError> {
        let _ = (conversation, hash, variant, bytes);
        Err(OpError::Rejected("attachments_unsupported".into()))
    }
    /// Streams a variant into a destination without retaining the original in RAM.
    /// Ports must reject premature EOF, oversized chunks and a mismatched length.
    fn attachment_into(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
        out: &mut dyn std::io::Write,
    ) -> Result<(), OpError> {
        let _ = (conversation, hash, variant, bytes, out);
        Err(OpError::Rejected("attachments_unsupported".into()))
    }
    /// `cloud-mux-ack`: the chief handled the wakes of `conversation` up to
    /// `seq` (the lease's chief; the request names no chief). Only the
    /// cloud port has a wake queue.
    fn mux_ack(&mut self, conversation: &str, seq: u64) -> Result<(), OpError> {
        let _ = (conversation, seq);
        Err(OpError::Rejected("mux_unsupported".into()))
    }

    /// Whether the owner advertised `capability` at connect (`identify`).
    fn supports(&self, _capability: &str) -> bool {
        false
    }
    /// A port for the link preview thread (its own connection, bound as
    /// the same agent): it reads the conversation and uploads pictures
    /// without blocking the brain. None: no link previews on this owner.
    fn preview_port(&self) -> Option<Box<dyn PreviewPort>> {
        None
    }
}

/// `link_preview` parts on the local conversation owner.
pub const LINK_PREVIEW_CAPABILITY: &str = "link-preview-v1";

/// What the link preview thread needs from the owner, off the brain thread.
pub trait PreviewPort: Send {
    /// The conversation and its last `tail` messages (for the people's URLs).
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError>;
    /// Uploads `bytes` (an image of `mime_type`, at most one 4 MiB chunk) as
    /// an attachment record of `conversation` that this connection's agent
    /// may send (`conversation-attachment-upload`: begin, chunk, commit).
    /// A hash the conversation already holds needs no bytes.
    fn upload_image(
        &mut self,
        conversation: &str,
        bytes: &[u8],
        mime_type: &str,
        name: &str,
        width: u32,
        height: u32,
    ) -> Result<DerivedImage, OpError>;

    /// The file at `path` as an attachment record of `conversation` (a
    /// picture or video the Chief sends, of any size): the same upload, read
    /// from the file a chunk at a time, with the size only when known.
    fn upload_attachment(
        &mut self,
        conversation: &str,
        path: &std::path::Path,
        mime_type: &str,
        name: &str,
        width: Option<u32>,
        height: Option<u32>,
    ) -> Result<DerivedImage, OpError>;
}

/// The bytes of an upload: in memory (a link preview picture, one chunk at
/// most), or a file that is hashed and then sent one chunk at a time, so a
/// file of any size never sits in memory whole.
#[derive(Clone, Copy)]
enum Source<'a> {
    Bytes(&'a [u8]),
    File(&'a std::path::Path),
}

impl Source<'_> {
    /// The SHA-256 (lowercase hex) and length of the bytes.
    fn digest(self) -> std::io::Result<(String, u64)> {
        use sha2::Digest;
        let mut hasher = sha2::Sha256::new();
        let len = match self {
            Source::Bytes(bytes) => {
                hasher.update(bytes);
                bytes.len() as u64
            }
            Source::File(path) => std::io::copy(&mut std::fs::File::open(path)?, &mut hasher)?,
        };
        let hash = hasher
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        Ok((hash, len))
    }
}

/// What is left to send of a [`Source`].
enum Chunks<'a> {
    Bytes(&'a [u8]),
    File(std::fs::File),
}

/// The upload steps of [`PreviewPort::upload_image`] on `client`.
#[allow(clippy::too_many_arguments)]
fn upload_with(
    client: &mut Client,
    conversation: &str,
    source: Source<'_>,
    mime_type: &str,
    name: &str,
    width: Option<u32>,
    height: Option<u32>,
) -> Result<DerivedImage, OpError> {
    upload_steps(
        &mut |request| {
            client
                .conversation_attachment_upload(request)
                .map_err(sdk_error)
        },
        conversation,
        source,
        mime_type,
        name,
        width,
        height,
    )
}

/// `conversation-attachment-upload` (begin, chunks, commit) through `step`,
/// one owner request per call.
#[allow(clippy::too_many_arguments)]
fn upload_steps(
    send: &mut dyn FnMut(
        ConversationAttachmentUploadRequest,
    ) -> Result<ConversationAttachmentUploadResult, OpError>,
    conversation: &str,
    source: Source<'_>,
    mime_type: &str,
    name: &str,
    width: Option<u32>,
    height: Option<u32>,
) -> Result<DerivedImage, OpError> {
    use base64::Engine;
    use std::io::Read;
    let unreadable =
        |e: std::io::Error| OpError::Transport(format!("reading the file failed: {e}"));
    let (hash, byte_count) = source.digest().map_err(unreadable)?;
    let image = DerivedImage {
        hash: hash.clone(),
        mime_type: mime_type.to_owned(),
        byte_count,
    };
    let step = |op: &str| ConversationAttachmentUploadRequest {
        op: op.into(),
        byte_count: Optional::Missing,
        conversation: Optional::Missing,
        data: Optional::Missing,
        duration_ms: Optional::Missing,
        height: Optional::Missing,
        mime_type: Optional::Missing,
        name: Optional::Missing,
        offset: Optional::Missing,
        piece: Optional::Missing,
        poster: Optional::Missing,
        preview: Optional::Missing,
        sha256: Optional::Missing,
        upload: Optional::Missing,
        width: Optional::Missing,
    };
    let stored = |result: &ConversationAttachmentUploadResult| -> Option<Result<(), OpError>> {
        let Optional::Value(stored) = &result.stored else {
            return None;
        };
        Some(
            if stored.hash == image.hash
                && stored.mime_type == image.mime_type
                && stored.byte_count == image.byte_count
            {
                Ok(())
            } else {
                Err(OpError::Rejected("attachment_mismatch".into()))
            },
        )
    };
    let begin = send(ConversationAttachmentUploadRequest {
        conversation: Optional::Value(conversation.into()),
        sha256: Optional::Value(hash),
        byte_count: Optional::Value(image.byte_count),
        mime_type: Optional::Value(mime_type.into()),
        name: Optional::Value(name.into()),
        width: width.map_or(Optional::Missing, Optional::Value),
        height: height.map_or(Optional::Missing, Optional::Value),
        ..step("begin")
    })?;
    if let Some(done) = stored(&begin) {
        return done.map(|()| image);
    }
    let Optional::Value(upload) = begin.upload else {
        return Err(OpError::Transport(
            "upload begin without an upload id".into(),
        ));
    };
    // The owner takes at most ATTACHMENT_CHUNK_BYTES a chunk (its
    // MAX_CHUNK_BYTES): a file sent whole over that is refused. A file is
    // read again one chunk at a time; one that changed since it was hashed
    // fails the owner's hash check at the commit.
    let mut remaining = match source {
        Source::Bytes(bytes) => Chunks::Bytes(bytes),
        Source::File(path) => Chunks::File(std::fs::File::open(path).map_err(unreadable)?),
    };
    let mut buffer = Vec::new();
    let mut offset = 0;
    while offset < byte_count {
        let length = (byte_count - offset).min(ATTACHMENT_CHUNK_BYTES);
        let chunk = match &mut remaining {
            Chunks::Bytes(bytes) => {
                let all: &[u8] = bytes;
                let (chunk, rest) = all.split_at((length as usize).min(all.len()));
                *bytes = rest;
                chunk
            }
            Chunks::File(file) => {
                buffer.clear();
                file.by_ref()
                    .take(length)
                    .read_to_end(&mut buffer)
                    .map_err(unreadable)?;
                &buffer[..]
            }
        };
        if chunk.is_empty() {
            return Err(OpError::Transport(
                "the file shrank while it was sent".into(),
            ));
        }
        send(ConversationAttachmentUploadRequest {
            upload: Optional::Value(upload.clone()),
            piece: Optional::Value("original".into()),
            offset: Optional::Value(offset),
            data: Optional::Value(base64::engine::general_purpose::STANDARD.encode(chunk)),
            ..step("chunk")
        })?;
        offset += chunk.len() as u64;
    }
    let commit = send(ConversationAttachmentUploadRequest {
        upload: Optional::Value(upload),
        ..step("commit")
    })?;
    match stored(&commit) {
        Some(done) => done.map(|()| image),
        None => Err(OpError::Transport("upload commit without a record".into())),
    }
}

/// What the brain hears from the daemon.
pub enum DaemonEvent {
    /// Connected, created or found the conversation and subscribed; `reconnect`
    /// drops the connection so the link connects (and binds) again.
    Up {
        port: Box<dyn ConversationPort>,
        conversation: Summary,
        reconnect: Box<dyn Fn() + Send>,
    },
    Changed {
        conversation: String,
        change: Change,
    },
    Down,
    /// The daemon cannot host local conversations: the host cannot run.
    Fatal(String),
    /// The chief's wake queue (`cloud-mux-wake`, `cloud-mux-resynced`): wakes
    /// by ids only, never message text. The brain reads a woken side
    /// conversation through its own authorized reads.
    MuxWake(Vec<MuxWake>),
}

/// One wake of the chief's queue: `conversation` has a message at `seq`
/// that the server's wake rule says the chief should read.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize)]
pub struct MuxWake {
    pub conversation: String,
    pub seq: u64,
    #[serde(default)]
    pub reason: String,
}

/// The participants of the Chief conversation, the same as the app's
/// (HomeService.mux, HomeChiefName.createRequest), so the owner replays the
/// app's create (one conversation, the app's Chief tab).
pub fn participants(display_name: &str) -> Vec<Participant> {
    chief_participants(display_name, AGENT_MUX, CHIEF_DISPLAY_NAME)
}

/// The participants of a Chief's own conversation: the person and the Chief
/// `chief` named `chief_name`; the default Chief is [`participants`].
pub fn chief_participants(display_name: &str, chief: &str, chief_name: &str) -> Vec<Participant> {
    let default = chief == AGENT_MUX;
    vec![
        Participant {
            id: USER_LOCAL.into(),
            kind: ParticipantKind::Human,
            display_name: display_name.into(),
            agent_class: None,
            acp_session: None,
            person: None,
        },
        Participant {
            id: chief.into(),
            kind: ParticipantKind::Agent,
            display_name: chief_name.into(),
            agent_class: Some(AgentClass::Mux),
            acp_session: default.then(|| MUX_SESSION_NAME.into()),
            person: None,
        },
    ]
}

/// The Mac user's full name (`id -F`), else the login name, as mux/host names user_local.
pub fn full_name() -> String {
    let out = std::process::Command::new("/usr/bin/id").arg("-F").output();
    if let Ok(out) = out
        && out.status.success()
    {
        let name = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        if !name.is_empty() {
            return name;
        }
    }
    std::env::var("USER").unwrap_or_else(|_| "user".into())
}

/// The token file's text, trimmed; None when missing or empty.
pub fn read_token(file: Option<&std::path::Path>) -> Option<String> {
    let text = std::fs::read_to_string(file?).ok()?;
    let token = text.trim();
    (!token.is_empty()).then(|| token.to_owned())
}

fn sdk_error(error: SdkError) -> OpError {
    match error {
        SdkError::Command { message, .. } => OpError::Rejected(message),
        SdkError::Protocol { code, message, .. } => OpError::Rejected(format!("{code}: {message}")),
        other => OpError::Transport(other.to_string()),
    }
}

fn decode<T: serde::de::DeserializeOwned>(value: Value, what: &str) -> Result<T, OpError> {
    serde_json::from_value(value).map_err(|e| OpError::Transport(format!("{what}: {e}")))
}

/// The SDK's generated wire struct as the brain's own type (cmux-conversation
/// is the owner's source of truth; the SDK mirrors it field for field).
fn rewire<S: serde::Serialize, T: serde::de::DeserializeOwned>(
    value: &S,
    what: &str,
) -> Result<T, OpError> {
    let json =
        serde_json::to_value(value).map_err(|e| OpError::Transport(format!("{what}: {e}")))?;
    decode(json, what)
}

/// The port over a cmux-sdk connection.
pub struct SdkConversations {
    client: Client,
    /// What the owner advertised at connect.
    capabilities: Vec<String>,
    /// How to open an uploader's own connection.
    config: LinkConfig,
}

/// The link preview thread's port: its own connection, opened and bound as
/// the chief's agent on first use and kept for the thread's reads and
/// uploads.
pub struct SdkPreviewPort {
    config: LinkConfig,
    client: Option<Client>,
}

impl SdkPreviewPort {
    fn client(&mut self) -> Result<&mut Client, OpError> {
        if self.client.is_none() {
            let sdk = ClientConfig::from_socket_path(&self.config.socket);
            let mut client = Client::connect(sdk).map_err(sdk_error)?;
            let token = read_token(self.config.token_file.as_deref()).ok_or_else(|| {
                OpError::Transport("MUX_AGENT_TOKEN_FILE is missing or empty".into())
            })?;
            client
                .conversation_bind(ConversationBindRequest {
                    participant: self.config.participant.clone(),
                    token,
                })
                .map_err(sdk_error)?;
            self.client = Some(client);
        }
        self.client
            .as_mut()
            .ok_or_else(|| OpError::Transport("no preview connection".into()))
    }
}

impl PreviewPort for SdkPreviewPort {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        snapshot_with(self.client()?, conversation, tail)
    }

    fn upload_image(
        &mut self,
        conversation: &str,
        bytes: &[u8],
        mime_type: &str,
        name: &str,
        width: u32,
        height: u32,
    ) -> Result<DerivedImage, OpError> {
        upload_with(
            self.client()?,
            conversation,
            Source::Bytes(bytes),
            mime_type,
            name,
            Some(width),
            Some(height),
        )
    }

    fn upload_attachment(
        &mut self,
        conversation: &str,
        path: &std::path::Path,
        mime_type: &str,
        name: &str,
        width: Option<u32>,
        height: Option<u32>,
    ) -> Result<DerivedImage, OpError> {
        upload_with(
            self.client()?,
            conversation,
            Source::File(path),
            mime_type,
            name,
            width,
            height,
        )
    }
}

/// `conversation-snapshot` on `client`, in the brain's types.
fn snapshot_with(
    client: &mut Client,
    conversation: &str,
    tail: u32,
) -> Result<(Summary, Vec<Message>), OpError> {
    let data = client
        .conversation_snapshot(ConversationSnapshotRequest {
            conversation: conversation.into(),
            tail,
        })
        .map_err(sdk_error)?;
    let summary = rewire(&data.conversation, "snapshot summary")?;
    let messages = rewire(&data.messages, "snapshot messages")?;
    Ok((summary, messages))
}

impl ConversationPort for SdkConversations {
    fn snapshot(
        &mut self,
        conversation: &str,
        tail: u32,
    ) -> Result<(Summary, Vec<Message>), OpError> {
        snapshot_with(&mut self.client, conversation, tail)
    }

    fn history(
        &mut self,
        conversation: &str,
        before_seq: u64,
        limit: u32,
    ) -> Result<Vec<Message>, OpError> {
        let data = self
            .client
            .conversation_history(ConversationHistoryRequest {
                before_seq,
                conversation: conversation.into(),
                limit,
            })
            .map_err(sdk_error)?;
        rewire(&data.messages, "history")
    }

    fn op(&mut self, conversation: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError> {
        let op = serde_json::to_value(op).map_err(|e| OpError::Transport(e.to_string()))?;
        let data = self
            .client
            .conversation_op(ConversationOpRequest {
                actor: Optional::Value(self.config.participant.clone()),
                conversation: conversation.into(),
                idempotency_key: key.into(),
                op: Nullable::value(op),
                transaction: Optional::Missing,
            })
            .map_err(sdk_error)?;
        Ok(rewire(&data.change, "op change").ok())
    }

    fn attachment(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
    ) -> Result<String, OpError> {
        use base64::Engine as _;
        // Only bounded model-image callers use the in-memory API. Files use
        // attachment_into directly, regardless of their original size.
        let mut whole = Vec::new();
        self.attachment_into(conversation, hash, variant, bytes, &mut whole)?;
        Ok(base64::engine::general_purpose::STANDARD.encode(whole))
    }

    fn attachment_into(
        &mut self,
        conversation: &str,
        hash: &str,
        variant: &str,
        bytes: u64,
        out: &mut dyn std::io::Write,
    ) -> Result<(), OpError> {
        use base64::Engine as _;
        let mut offset = 0u64;
        loop {
            let length = bytes.saturating_sub(offset).min(ATTACHMENT_CHUNK_BYTES);
            let data = self
                .client
                .conversation_attachment_read(ConversationAttachmentReadRequest {
                    conversation: conversation.into(),
                    hash: hash.into(),
                    length: Optional::Value(length),
                    offset: Optional::Value(offset),
                    variant: Optional::Value(variant.into()),
                })
                .map_err(sdk_error)?;
            if data.data.len() as u64 > length.div_ceil(3) * 4 {
                return Err(OpError::Rejected("attachment_length_mismatch".into()));
            }
            let chunk = base64::engine::general_purpose::STANDARD
                .decode(data.data.as_bytes())
                .map_err(|e| OpError::Rejected(format!("attachment_bad_base64: {e}")))?;
            if chunk.len() as u64 > length {
                return Err(OpError::Rejected("attachment_length_mismatch".into()));
            }
            offset += chunk.len() as u64;
            out.write_all(&chunk)
                .map_err(|e| OpError::Transport(format!("attachment_write: {e}")))?;
            if data.eof {
                return if offset == bytes {
                    Ok(())
                } else {
                    Err(OpError::Rejected("attachment_ended_early".into()))
                };
            }
            if chunk.is_empty() || offset >= bytes {
                return Err(OpError::Rejected("attachment_length_mismatch".into()));
            }
        }
    }

    fn typing(&mut self, conversation: &str, on: bool) -> Result<(), OpError> {
        self.client
            .conversation_typing(ConversationTypingRequest {
                actor: Optional::Value(self.config.participant.clone()),
                conversation: conversation.into(),
                on,
            })
            .map(|_| ())
            .map_err(sdk_error)
    }

    fn supports(&self, capability: &str) -> bool {
        self.capabilities.iter().any(|c| c == capability)
    }

    /// The local owner has no wake queue (`membership`): the brain's saved
    /// floor of each side conversation is the only record, so there is
    /// nothing to ack.
    fn mux_ack(&mut self, conversation: &str, seq: u64) -> Result<(), OpError> {
        let _ = (conversation, seq);
        Ok(())
    }

    fn preview_port(&self) -> Option<Box<dyn PreviewPort>> {
        Some(Box::new(SdkPreviewPort {
            config: self.config.clone(),
            client: None,
        }))
    }

    fn upload_run_image(
        &mut self,
        conversation: &str,
        bytes: &[u8],
        mime_type: &str,
        name: &str,
        width: u32,
        height: u32,
    ) -> Result<DerivedImage, OpError> {
        upload_with(
            &mut self.client,
            conversation,
            Source::Bytes(bytes),
            mime_type,
            name,
            Some(width),
            Some(height),
        )
    }

    /// `conversation-run-append` (capability `conversation-runs-v1`): this
    /// bound connection's principal is the Chief that writes its run.
    fn run_append(
        &mut self,
        conversation: &str,
        run: Value,
        steps: Vec<Value>,
    ) -> Result<(), OpError> {
        if !self.supports("conversation-runs-v1") {
            return Err(OpError::Rejected("runs_unsupported".into()));
        }
        self.client
            .conversation_run_append(ConversationRunAppendRequest {
                conversation: conversation.into(),
                run: Nullable::value(run),
                steps: Some(steps),
            })
            .map(|_| ())
            .map_err(sdk_error)
    }

    /// `conversation-live-publish` (capability `chief-live-v1`): this bound
    /// connection's principal is the Chief whose run streams.
    fn live_publish(&mut self, conversation: &str, frame: Value) -> Result<(), OpError> {
        if !self.supports("chief-live-v1") {
            return Err(OpError::Rejected("live_unsupported".into()));
        }
        self.client
            .conversation_live_publish(ConversationLivePublishRequest {
                conversation: conversation.into(),
                frame: Nullable::value(frame),
            })
            .map(|_| ())
            .map_err(sdk_error)
    }

    /// `conversation-draft` (capability `conversation-draft-v1`): the v1
    /// command of `conversation.draft`; this bound connection's principal is
    /// `agent_mux` (conversation-bind).
    fn draft(&mut self, conversation: &str, draft: &crate::draft::Draft) -> Result<(), OpError> {
        self.client
            .conversation_draft(ConversationDraftRequest {
                conversation: conversation.into(),
                turn: draft.turn.clone(),
                segment: draft.segment,
                seq: draft.seq,
                kind: draft.kind.into(),
                text: draft.text.clone(),
                fresh: draft.fresh,
                done: draft.done,
                truncated: Optional::Value(draft.truncated),
                harness: match &draft.harness {
                    Some(harness) => Optional::Value(harness.clone()),
                    None => Optional::Missing,
                },
            })
            .map(|_| ())
            .map_err(sdk_error)
    }
}

enum ConnectError {
    Missing(String),
    Other(String),
}

/// How the link connects.
#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub socket: PathBuf,
    pub token_file: Option<PathBuf>,
    pub display_name: String,
    /// The create request's title: the app's (localized) Chief name; for a
    /// Chief that is not the default, also its participant name.
    pub title: String,
    /// The participant the link binds as (`membership`; default agent_mux).
    pub participant: String,
}

impl LinkConfig {
    /// The app's names for the create request: `MUX_USER_NAME` (the app's
    /// user name) and `MUX_CHIEF_TITLE` (its localized Chief title), else
    /// the Mac's full name and "Chief".
    pub fn names_from_env() -> (String, String) {
        let var = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        (
            var("MUX_USER_NAME").unwrap_or_else(full_name),
            var("MUX_CHIEF_TITLE").unwrap_or_else(|| CHIEF_CONVERSATION_TITLE.into()),
        )
    }
}

/// The Chief conversation among `conversations`, by the rule the app shares
/// (HomeChiefName.select, select_chief_conversation): the oldest conversation
/// with agent_mux, by created_at, then id.
pub fn select_chief(conversations: Vec<Summary>) -> Option<Summary> {
    select_chief_of(conversations, AGENT_MUX)
}

/// [`select_chief`] for the Chief `chief`. A Chief that is not agent_mux
/// answers in its oldest DM with the person (the person and the Chief only;
/// the person's paired devices do not count, see [`is_the_person`]); None
/// when it has none, so the link creates it (a channel never becomes a
/// Chief's main conversation).
pub fn select_chief_of(conversations: Vec<Summary>, chief: &str) -> Option<Summary> {
    if chief != AGENT_MUX {
        return conversations
            .into_iter()
            .filter(|c| {
                c.participants.iter().any(|p| p.id == chief)
                    && c.participants.iter().any(|p| p.id == USER_LOCAL)
                    && c.participants
                        .iter()
                        .all(|p| p.id == chief || is_the_person(p))
            })
            .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)));
    }
    conversations
        .into_iter()
        .filter(|c| c.participants.iter().any(|p| p.id == chief))
        .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)))
}

/// True for the person: `user_local`, or a paired device of the person (a
/// `remote_<install>` participant whose `person` is `user_local`; pairing
/// adds it to every conversation of the person). A device does not make a
/// DM a group.
fn is_the_person(participant: &Participant) -> bool {
    participant.id == USER_LOCAL || participant.person.as_deref() == Some(USER_LOCAL)
}

enum CreateError {
    Conflict(SdkError),
    Other(ConnectError),
}

/// The owner's `conversation-create` of a Chief's own conversation under
/// `key`: the person named `display_name` and the Chief `chief` named
/// `chief_name`, titled `title`. A request equal to the one that made the
/// conversation replays it; another one under the same key is
/// [`CreateError::Conflict`].
fn create_keyed(
    client: &mut Client,
    key: &str,
    title: &str,
    display_name: &str,
    chief: &str,
    chief_name: &str,
) -> Result<Summary, CreateError> {
    let participants = serde_json::to_value(chief_participants(display_name, chief, chief_name))
        .map_err(|e| CreateError::Other(ConnectError::Other(format!("participants: {e}"))))?;
    let created = client.conversation_create(ConversationCreateRequest {
        actor: Optional::Value(USER_LOCAL.into()),
        idempotency_key: key.to_owned(),
        participants: Nullable::value(participants),
        title: title.to_owned(),
    });
    match created {
        Ok(created) => rewire(&created.conversation, "conversation-create")
            .map_err(|e| CreateError::Other(ConnectError::Other(e.to_string()))),
        Err(e) if is_idempotency_conflict(&e) => Err(CreateError::Conflict(e)),
        Err(e) => Err(CreateError::Other(ConnectError::Other(e.to_string()))),
    }
}

/// The owner's refusal of a key reused with another request: a v1
/// `conversation_rejected` whose reason is `idempotency_conflict`
/// (conversation_store.rs), or the v2 code itself.
fn is_idempotency_conflict(error: &SdkError) -> bool {
    match error {
        SdkError::Command {
            message,
            error_code,
            ..
        } => {
            error_code.as_deref() == Some("idempotency_conflict")
                || (error_code.as_deref() == Some("conversation_rejected")
                    && message.trim() == "idempotency_conflict")
        }
        other => other.error_code() == Some("idempotency_conflict"),
    }
}

/// The conversation an `idempotency_conflict` names (`error_details.conversation`,
/// cmux-tui-core conversation_store.rs `KeyedConversation`).
fn keyed_conversation(error: &SdkError) -> Option<String> {
    match error {
        SdkError::Command {
            error_details: Some(details),
            ..
        } => details
            .get("conversation")
            .and_then(Value::as_str)
            .map(str::to_owned),
        _ => None,
    }
}

/// The most distinct requests [`find_grown_dm`] sends the owner.
const GROWN_DM_PROBES: usize = 8;

/// The conversation `key` made, after the owner refused a create under `key`
/// as `idempotency_conflict` (so it exists), when it is no longer a
/// two-person DM. Each conversation with the person and `chief` (oldest
/// first) is asked for with the request that would have made it (its own
/// title and names, which a DM keeps unless someone changed them): the owner
/// replays only the conversation `key` made, so a channel is never taken for
/// the DM, and it writes nothing. `Ok(None)` when none replays (the DM's
/// title or names changed since it was made): the brain does not guess.
fn find_grown_dm(
    client: &mut Client,
    key: &str,
    listed: Vec<Summary>,
    chief: &str,
) -> Result<Option<Summary>, ConnectError> {
    let mut candidates: Vec<Summary> = listed
        .into_iter()
        .filter(|c| {
            c.participants.iter().any(|p| p.id == chief)
                && c.participants.iter().any(|p| p.id == USER_LOCAL)
        })
        .collect();
    candidates.sort_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)));
    let mut asked: Vec<(String, String, String)> = Vec::new();
    for candidate in &candidates {
        let name = |id: &str| {
            candidate
                .participants
                .iter()
                .find(|p| p.id == id)
                .map(|p| p.display_name.clone())
                .unwrap_or_default()
        };
        let request = (candidate.title.clone(), name(USER_LOCAL), name(chief));
        if asked.contains(&request) {
            continue;
        }
        if asked.len() == GROWN_DM_PROBES {
            break;
        }
        asked.push(request);
        let (title, person, chief_name) = asked.last().unwrap();
        match create_keyed(client, key, title, person, chief, chief_name) {
            // A conversation the Chief has left is not its DM.
            Ok(found) if found.participants.iter().any(|p| p.id == chief) => {
                return Ok(Some(found));
            }
            Ok(_) => return Ok(None),
            Err(CreateError::Conflict(_)) => {}
            Err(CreateError::Other(e)) => return Err(e),
        }
    }
    Ok(None)
}

/// A connected, bound link: the client, its conversation, its event stream
/// and the owner's capabilities.
type Connected = (Client, Summary, cmux::raw::Stream, Vec<String>);

fn connect(config: &LinkConfig) -> Result<Connected, ConnectError> {
    let other = |e: SdkError| ConnectError::Other(e.to_string());
    let sdk = ClientConfig::from_socket_path(&config.socket);
    let mut client = Client::connect(sdk.clone()).map_err(other)?;
    // Read leniently (only the capabilities matter here), as mux/host does,
    // so a daemon that adds or drops other identify fields still connects.
    let mut identify = serde_json::Map::new();
    identify.insert("cmd".into(), Value::String("identify".into()));
    let identity = client.request_raw(identify).map_err(other)?;
    let data = identity.get("data").cloned().unwrap_or(Value::Null);
    let capabilities: Vec<String> = data
        .get("capabilities")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|c| c.as_str().map(str::to_owned))
        .collect();
    let capable = capabilities.iter().any(|c| c == CAPABILITY);
    if !capable {
        let text = |k: &str| {
            data.get(k)
                .map(|v| v.to_string())
                .unwrap_or_else(|| "?".into())
        };
        return Err(ConnectError::Missing(format!(
            "daemon at {} ({} {}) lacks {CAPABILITY}",
            config.socket.display(),
            text("app"),
            text("version")
        )));
    }
    // The app creates the Chief conversation when Home opens; answer in the
    // one it shows. Create it (with the app's exact request, so the owner
    // replays one conversation) only when none exists yet.
    let listed = client
        .conversation_list(ConversationListRequest {})
        .map_err(other)?;
    let listed: Vec<Summary> = rewire(&listed.conversations, "conversation-list")
        .map_err(|e| ConnectError::Other(e.to_string()))?;
    let summary = match select_chief_of(listed.clone(), &config.participant) {
        Some(found) => found,
        None => {
            let key = if config.participant == AGENT_MUX {
                DEFAULT_CONVERSATION_KEY.to_owned()
            } else {
                format!("{DEFAULT_CONVERSATION_KEY}-{}", config.participant)
            };
            let chief_name = if config.participant == AGENT_MUX {
                CHIEF_DISPLAY_NAME
            } else {
                config.title.as_str()
            };
            match create_keyed(
                &mut client,
                &key,
                &config.title,
                &config.display_name,
                &config.participant,
                chief_name,
            ) {
                Ok(created) => created,
                // The key made this Chief's DM earlier with other names (a
                // rename), and the DM has since gained a participant, so the
                // select above missed it. Answer there; a new key would make
                // a second DM. The DM keeps its stored title.
                Err(CreateError::Conflict(e)) => {
                    // The owner names the conversation the key made (to a
                    // creator that takes part in it): that is the DM, also
                    // when its title changed. An older owner names none.
                    let keyed = keyed_conversation(&e).and_then(|id| {
                        listed.iter().find(|c| {
                            c.id == id && c.participants.iter().any(|p| p.id == config.participant)
                        })
                    });
                    if let Some(found) = keyed.cloned() {
                        found
                    } else {
                        match find_grown_dm(&mut client, &key, listed, &config.participant)? {
                            Some(found) => found,
                            None => {
                                return Err(ConnectError::Other(format!(
                                    "{e}: no conversation with the person replays {key}; its DM's title or names changed"
                                )));
                            }
                        }
                    }
                }
                Err(CreateError::Other(e)) => return Err(e),
            }
        }
    };
    // Read at every connect: the app mints a new token on each launch.
    match read_token(config.token_file.as_deref()) {
        Some(token) => {
            client
                .conversation_bind(ConversationBindRequest {
                    participant: config.participant.clone(),
                    token,
                })
                .map_err(other)?;
        }
        None => {
            return Err(ConnectError::Other(
                "MUX_AGENT_TOKEN_FILE is missing or empty".into(),
            ));
        }
    }
    // Events arrive on their own connection; subscribing before the brain's
    // snapshot means no change falls between the two.
    let stream = client
        .subscribe(SubscribeRequest {
            surface: Optional::Missing,
            tree_events: Optional::Value(SubscribeRequestTreeEvents::Deltas),
        })
        .map_err(other)?;
    Ok((client, summary, stream, capabilities))
}

/// Runs the daemon connection loop on its own thread.
pub fn spawn_link(
    config: LinkConfig,
    sink: Arc<dyn Fn(DaemonEvent) + Send + Sync>,
    log: Arc<dyn Fn(&str) + Send + Sync>,
) {
    let fatal = sink.clone();
    let spawned = std::thread::Builder::new()
        .name("daemon-link".into())
        .spawn(move || {
            let mut delay = Duration::from_millis(500);
            loop {
                let started = Instant::now();
                match connect(&config) {
                    Ok((client, conversation, mut stream, capabilities)) => {
                        log(&format!(
                            "daemon connected; conversation {}",
                            conversation.id
                        ));
                        let closer = stream.closer();
                        sink(DaemonEvent::Up {
                            port: Box::new(SdkConversations {
                                client,
                                capabilities,
                                config: config.clone(),
                            }),
                            conversation,
                            reconnect: Box::new(move || closer.close()),
                        });
                        loop {
                            match stream.recv() {
                                Ok(Event::ConversationChanged(event)) => {
                                    let change = event
                                        .change
                                        .into_option()
                                        .and_then(|c| serde_json::from_value(c).ok());
                                    if let Some(change) = change {
                                        sink(DaemonEvent::Changed {
                                            conversation: event.conversation,
                                            change,
                                        });
                                    }
                                }
                                Ok(other) if other.wire_name() == Some("overflow") => {
                                    // Fell behind: the reconnect catches up from the read cursor.
                                    log("daemon subscription overflow; resubscribing");
                                    break;
                                }
                                Ok(_) => {}
                                Err(SdkError::Timeout(_)) => {}
                                Err(e) => {
                                    log(&format!("daemon connection closed: {e}"));
                                    break;
                                }
                            }
                        }
                        sink(DaemonEvent::Down);
                    }
                    Err(ConnectError::Missing(why)) => {
                        sink(DaemonEvent::Fatal(why));
                        return;
                    }
                    Err(ConnectError::Other(e)) => log(&format!("daemon: {e}")),
                }
                if started.elapsed() > Duration::from_secs(30) {
                    delay = Duration::from_millis(500);
                }
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(30));
            }
        });
    if let Err(e) = spawned {
        fatal(DaemonEvent::Fatal(format!(
            "cannot start the daemon link thread: {e}"
        )));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;
    use cmux::raw::ConversationAttachmentUploadResultStored;

    /// The owner's upload rules (cmux-tui conversation_attachments.rs): one
    /// chunk carries at most 4 MiB, at exactly the received offset, and the
    /// commit stores the file only when every byte came.
    #[derive(Default)]
    struct Owner {
        declared: Option<(String, u64, String)>,
        received: Vec<u8>,
        chunks: Vec<(u64, usize)>,
    }

    impl Owner {
        fn step(
            &mut self,
            request: ConversationAttachmentUploadRequest,
        ) -> Result<ConversationAttachmentUploadResult, OpError> {
            let refused = |code: &str| Err(OpError::Rejected(code.into()));
            match request.op.as_str() {
                "begin" => {
                    let (Optional::Value(hash), Optional::Value(count), Optional::Value(mime)) =
                        (request.sha256, request.byte_count, request.mime_type)
                    else {
                        return refused("bad_begin");
                    };
                    self.declared = Some((hash, count, mime));
                    Ok(ConversationAttachmentUploadResult {
                        upload: Optional::Value("up-1".into()),
                        ..Default::default()
                    })
                }
                "chunk" => {
                    let (Optional::Value(offset), Optional::Value(data)) =
                        (request.offset, request.data)
                    else {
                        return refused("bad_chunk");
                    };
                    let bytes = base64::engine::general_purpose::STANDARD
                        .decode(data)
                        .map_err(|_| OpError::Rejected("bad_base64".into()))?;
                    if bytes.len() > ATTACHMENT_CHUNK_BYTES as usize {
                        return refused("chunk_too_large");
                    }
                    if offset != self.received.len() as u64 {
                        return refused("bad_offset");
                    }
                    self.chunks.push((offset, bytes.len()));
                    self.received.extend_from_slice(&bytes);
                    Ok(ConversationAttachmentUploadResult {
                        received: Optional::Value(self.received.len() as u64),
                        ..Default::default()
                    })
                }
                "commit" => {
                    let Some((hash, count, mime)) = self.declared.clone() else {
                        return refused("unknown_upload");
                    };
                    if self.received.len() as u64 != count {
                        return refused("incomplete");
                    }
                    Ok(ConversationAttachmentUploadResult {
                        stored: Optional::Value(ConversationAttachmentUploadResultStored {
                            byte_count: count,
                            hash,
                            mime_type: mime,
                            poster: Optional::Missing,
                            preview: Optional::Missing,
                        }),
                        ..Default::default()
                    })
                }
                _ => refused("bad_op"),
            }
        }
    }

    fn upload(owner: &mut Owner, bytes: &[u8]) -> Result<DerivedImage, OpError> {
        upload_steps(
            &mut |request| owner.step(request),
            "conv-1",
            Source::Bytes(bytes),
            "image/png",
            "shot.png",
            Some(10),
            Some(10),
        )
    }

    /// The user's 9.2 MB screenshot (2026-10-26) came back `chunk_too_large`
    /// and showed as the text `!alarm-fired-100542Z.png` in Home.
    #[test]
    fn a_file_larger_than_one_chunk_uploads_in_4_mib_chunks() {
        let bytes: Vec<u8> = (0..9_216_808u32).map(|i| (i % 251) as u8).collect();
        let mut owner = Owner::default();
        let stored = upload(&mut owner, &bytes).expect("the upload is stored");
        assert_eq!(stored.byte_count, bytes.len() as u64);
        assert_eq!(owner.received, bytes);
        let chunk = ATTACHMENT_CHUNK_BYTES as usize;
        assert_eq!(
            owner.chunks,
            vec![
                (0, chunk),
                (chunk as u64, chunk),
                (2 * chunk as u64, bytes.len() - 2 * chunk)
            ]
        );
    }

    /// The Chief sends a file of any size from disk: the same chunks as the
    /// bytes, read one chunk at a time.
    #[test]
    fn a_file_on_disk_uploads_in_4_mib_chunks() {
        let bytes: Vec<u8> = (0..9_216_808u32).map(|i| (i % 251) as u8).collect();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("clip.mp4");
        std::fs::write(&path, &bytes).unwrap();
        let mut owner = Owner::default();
        let stored = upload_steps(
            &mut |request| owner.step(request),
            "conv-1",
            Source::File(&path),
            "video/mp4",
            "clip.mp4",
            None,
            None,
        )
        .expect("the upload is stored");
        assert_eq!(stored.byte_count, bytes.len() as u64);
        assert_eq!(owner.received, bytes);
        let chunk = ATTACHMENT_CHUNK_BYTES as usize;
        assert_eq!(
            owner.chunks,
            vec![
                (0, chunk),
                (chunk as u64, chunk),
                (2 * chunk as u64, bytes.len() - 2 * chunk)
            ]
        );
    }

    #[test]
    fn a_small_file_takes_one_chunk() {
        let mut owner = Owner::default();
        upload(&mut owner, b"tiny picture").expect("the upload is stored");
        assert_eq!(owner.chunks, vec![(0, 12)]);
    }

    #[test]
    fn a_file_of_exactly_one_chunk_takes_one_chunk() {
        let bytes = vec![7u8; ATTACHMENT_CHUNK_BYTES as usize];
        let mut owner = Owner::default();
        upload(&mut owner, &bytes).expect("the upload is stored");
        assert_eq!(owner.chunks, vec![(0, bytes.len())]);
    }
}

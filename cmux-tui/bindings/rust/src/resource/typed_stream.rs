use super::id::*;
use super::model::{
    AgentSnapshot, BrowserSnapshot, ClientSnapshot, Cursor, Document, FrontendProjectionSnapshot,
    MachineSnapshot, NotificationSnapshot, PairingRequestSnapshot, PaneSnapshot,
    ResourceEntitySnapshot, ResourceSnapshot, ScreenSnapshot, SessionSnapshot, SidebarViewSnapshot,
    StreamEnd, StreamItem, StreamPoll, TabSnapshot, TerminalSnapshot, TypedStreamItem,
    WorkspaceSnapshot,
};
use super::ops;
use super::options::{PixelSize, Size};
use super::stream::{ResourceStream, StreamCancellation, StreamItemValidator};
use super::wire::{self, Params, field};
use crate::{Error, Result};
use base64::Engine;
use serde_json::{Map, Value};
use std::time::Duration;

pub(crate) fn stream_item_validator(operation: &str) -> Result<StreamItemValidator> {
    Ok(match operation {
        ops::SESSION_EVENTS => validate_session_stream_item,
        ops::SESSION_JOURNAL_SUBSCRIBE => validate_session_journal_item,
        ops::TERMINAL_ATTACH => validate_terminal_stream_item,
        ops::BROWSER_ATTACH => validate_browser_stream_item,
        ops::SIDEBAR_VIEW_ATTACH => validate_sidebar_stream_item,
        _ => {
            return Err(Error::InvalidArgument(format!(
                "{operation} has no typed stream item decoder"
            )));
        }
    })
}

fn validate_session_stream_item(item: &StreamItem) -> Result<()> {
    decode_session_event(item.value.clone(), item.cursor.clone(), item.sequence).map(drop)
}

fn validate_session_journal_item(item: &StreamItem) -> Result<()> {
    decode_session_journal_record(item.value.clone(), item.cursor.clone(), item.sequence).map(drop)
}

fn validate_terminal_stream_item(item: &StreamItem) -> Result<()> {
    decode_terminal_item(item.value.clone(), item.cursor.clone(), item.sequence).map(drop)
}

fn validate_browser_stream_item(item: &StreamItem) -> Result<()> {
    decode_browser_item(item.value.clone(), item.cursor.clone(), item.sequence).map(drop)
}

fn validate_sidebar_stream_item(item: &StreamItem) -> Result<()> {
    decode_sidebar_item(item.value.clone(), item.cursor.clone(), item.sequence).map(drop)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResetReason {
    Initial,
    GenerationChanged,
    CursorExpired,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResourceKind {
    Machine,
    Session,
    Workspace,
    Screen,
    Pane,
    Tab,
    Terminal,
    Browser,
    Client,
    Notification,
    Agent,
    PairingRequest,
    FrontendProjection,
    SidebarView,
}

impl ResourceKind {
    fn parse(value: &str) -> Result<Self> {
        Ok(match value {
            "machine" => Self::Machine,
            "session" => Self::Session,
            "workspace" => Self::Workspace,
            "screen" => Self::Screen,
            "pane" => Self::Pane,
            "tab" => Self::Tab,
            "terminal" => Self::Terminal,
            "browser" => Self::Browser,
            "client" => Self::Client,
            "notification" => Self::Notification,
            "agent" => Self::Agent,
            "pairing_request" => Self::PairingRequest,
            "frontend_projection" => Self::FrontendProjection,
            "sidebar_view" => Self::SidebarView,
            _ => {
                return Err(Error::UnexpectedEnvelope(format!("unknown resource kind {value}")));
            }
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ResourceReference {
    Machine(MachineId),
    Session(SessionId),
    Workspace(WorkspaceId),
    Screen(ScreenId),
    Pane(PaneId),
    Tab(TabId),
    Terminal(TerminalId),
    Browser(BrowserId),
    Client(ConnectedClientId),
    Notification(NotificationId),
    Agent(AgentId),
    PairingRequest(PairingRequestId),
    FrontendProjection(FrontendProjectionId),
    SidebarView(SidebarViewId),
}

impl ResourceReference {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Machine(id) => id.as_str(),
            Self::Session(id) => id.as_str(),
            Self::Workspace(id) => id.as_str(),
            Self::Screen(id) => id.as_str(),
            Self::Pane(id) => id.as_str(),
            Self::Tab(id) => id.as_str(),
            Self::Terminal(id) => id.as_str(),
            Self::Browser(id) => id.as_str(),
            Self::Client(id) => id.as_str(),
            Self::Notification(id) => id.as_str(),
            Self::Agent(id) => id.as_str(),
            Self::PairingRequest(id) => id.as_str(),
            Self::FrontendProjection(id) => id.as_str(),
            Self::SidebarView(id) => id.as_str(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum ResourceChange {
    Upsert {
        sequence: u32,
        resource: ResourceKind,
        id: ResourceReference,
        value: ResourceEntitySnapshot,
    },
    Delete {
        sequence: u32,
        resource: ResourceKind,
        id: ResourceReference,
    },
    Unknown {
        kind: String,
        raw: Document,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSnapshotEvent {
    pub cursor: Cursor,
    pub reset_reason: Option<ResetReason>,
    pub snapshot: ResourceSnapshot,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionDeltaEvent {
    pub cursor: Cursor,
    pub previous_revision: u64,
    pub revision: u64,
    pub changes: Vec<ResourceChange>,
}

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum SessionEvent {
    Snapshot(SessionSnapshotEvent),
    Delta(SessionDeltaEvent),
    Unknown { kind: String, raw: Document },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalClass {
    State,
    Observation,
    Effect,
    Checkpoint,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalReplayPolicy {
    Required,
    Advisory,
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalSensitivity {
    Public,
    Metadata,
    Sensitive,
    Secret,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalProducer {
    pub kind: String,
    pub id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalAuthority {
    pub principal_id: String,
    pub lease_id: String,
    pub generation: String,
    pub role: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalSubject {
    pub kind: String,
    pub id: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionJournalRecord {
    pub sequence: u64,
    pub event_id: String,
    pub schema_version: u32,
    pub kind: String,
    pub class: JournalClass,
    pub replay: JournalReplayPolicy,
    pub occurred_at_ms: u64,
    pub committed_at_ms: u64,
    pub producer: JournalProducer,
    pub authority: Option<JournalAuthority>,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub causation_depth: u16,
    pub subjects: Vec<JournalSubject>,
    pub sensitivity: JournalSensitivity,
    pub payload: Value,
    pub resource_revision: Option<u64>,
    pub previous_resource_revision: Option<u64>,
}

/// Validated lowercase `#rrggbb` protocol color.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ColorHex(String);

impl ColorHex {
    pub fn parse(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        if !valid_color(&value) {
            return Err(Error::InvalidArgument("color must be lowercase #rrggbb".to_string()));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn valid_color(value: &str) -> bool {
    value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderCursorStyle {
    Block,
    Underline,
    Bar,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderUnderline {
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderCursor {
    pub x: u16,
    pub y: u16,
    pub style: RenderCursorStyle,
    pub blink: bool,
    pub visible: bool,
    pub color: Option<ColorHex>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderRun {
    pub text: String,
    pub fg: Option<ColorHex>,
    pub bg: Option<ColorHex>,
    pub attrs: u32,
    pub underline: Option<RenderUnderline>,
    pub width_hint: Option<u16>,
}

impl RenderRun {
    pub const ATTR_BOLD: u32 = 0x0001;
    pub const ATTR_ITALIC: u32 = 0x0002;
    pub const ATTR_STRIKETHROUGH: u32 = 0x0004;
    pub const ATTR_INVERSE: u32 = 0x0008;
    pub const ATTR_FAINT: u32 = 0x0010;
    pub const ATTR_INVISIBLE: u32 = 0x0020;
    pub const ATTR_BLINK: u32 = 0x0040;

    pub fn has_attr(&self, attr: u32) -> bool {
        self.attrs & attr != 0
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderRow {
    pub row: u16,
    pub runs: Vec<RenderRun>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderSnapshot {
    pub size: Size,
    pub cursor: RenderCursor,
    pub default_fg: ColorHex,
    pub default_bg: ColorHex,
    pub scrollback_rows: u32,
    pub rows: Vec<RenderRow>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderPatch {
    pub cursor: RenderCursor,
    pub full_reset: bool,
    pub size: Option<Size>,
    pub default_fg: Option<ColorHex>,
    pub default_bg: Option<ColorHex>,
    pub scrollback_rows: Option<u32>,
    pub rows: Vec<RenderRow>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RenderScroll {
    pub offset: u64,
    pub at_bottom: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TerminalAttachmentItem {
    Snapshot { terminal_id: TerminalId, render: RenderSnapshot },
    Patch { terminal_id: TerminalId, render: RenderPatch },
    Scroll { terminal_id: TerminalId, scroll: RenderScroll },
    Unknown { kind: String, raw: Document },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrowserFrameMime {
    Png,
    Jpeg,
}

#[derive(Clone, Debug, PartialEq)]
pub enum BrowserAttachmentItem {
    Snapshot {
        browser: BrowserSnapshot,
        size: PixelSize,
    },
    Frame {
        mime_type: BrowserFrameMime,
        data: Vec<u8>,
        size: PixelSize,
        pointer_frame_seq: Option<u64>,
    },
    State {
        url: String,
        title: String,
        loading: bool,
    },
    Unknown {
        kind: String,
        raw: Document,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum SidebarViewItem {
    Snapshot { sidebar_view: SidebarViewSnapshot, render: RenderSnapshot },
    Patch { sidebar_view_id: SidebarViewId, render: RenderPatch },
    Scroll { sidebar_view_id: SidebarViewId, scroll: RenderScroll },
    Unknown { kind: String, raw: Document },
}

macro_rules! typed_stream {
    ($name:ident, $item:ty, $decode:ident) => {
        pub struct $name {
            inner: ResourceStream,
            finished: bool,
        }

        impl $name {
            pub(crate) fn new(stream: ResourceStream) -> Self {
                Self { inner: stream, finished: false }
            }

            pub fn id(&self) -> &StreamId {
                self.inner.id()
            }

            pub fn cancellation(&self) -> StreamCancellation {
                self.inner.cancellation()
            }

            pub fn cancel(&mut self) -> Result<()> {
                self.inner.cancel()
            }

            pub fn end(&self) -> Option<&StreamEnd> {
                self.inner.end()
            }

            pub fn recv(&mut self) -> Result<Option<TypedStreamItem<$item>>> {
                if self.finished {
                    return Ok(None);
                }
                match self.inner.recv() {
                    Ok(Some(item)) => {
                        let sequence = item.sequence;
                        let cursor = item.cursor;
                        let value = $decode(item.value, cursor.clone(), sequence)?;
                        Ok(Some(TypedStreamItem { sequence, cursor, value }))
                    }
                    Ok(None) => {
                        self.finished = true;
                        Ok(None)
                    }
                    Err(error) => {
                        self.finished = true;
                        Err(error)
                    }
                }
            }

            /// Waits at most `timeout` for one item while leaving the stream open on timeout.
            pub fn next_timeout(
                &mut self,
                timeout: Duration,
            ) -> Result<StreamPoll<TypedStreamItem<$item>>> {
                if self.finished {
                    return Ok(StreamPoll::End);
                }
                match self.inner.recv_timeout(timeout)? {
                    StreamPoll::Item(item) => {
                        let sequence = item.sequence;
                        let cursor = item.cursor;
                        let value = $decode(item.value, cursor.clone(), sequence)?;
                        Ok(StreamPoll::Item(TypedStreamItem { sequence, cursor, value }))
                    }
                    StreamPoll::End => {
                        self.finished = true;
                        Ok(StreamPoll::End)
                    }
                    StreamPoll::TimedOut => Ok(StreamPoll::TimedOut),
                }
            }
        }

        impl Iterator for $name {
            type Item = Result<TypedStreamItem<$item>>;

            fn next(&mut self) -> Option<Self::Item> {
                match self.recv() {
                    Ok(Some(item)) => Some(Ok(item)),
                    Ok(None) => None,
                    Err(error) => Some(Err(error)),
                }
            }
        }
    };
}

typed_stream!(SessionEventStream, SessionEvent, decode_session_event);
typed_stream!(SessionJournalStream, SessionJournalRecord, decode_session_journal_record);
typed_stream!(TerminalAttachment, TerminalAttachmentItem, decode_terminal_item);
typed_stream!(BrowserAttachment, BrowserAttachmentItem, decode_browser_item);
typed_stream!(SidebarViewStream, SidebarViewItem, decode_sidebar_item);

impl TerminalAttachment {
    /// Updates the viewer lease on this attachment's owned stream connection.
    pub fn resize(&mut self, size: Size) -> Result<super::model::ViewerResizeResult> {
        wire::validate_size(size)?;
        let attachment_lease = self
            .inner
            .attachment_lease()
            .ok_or_else(|| Error::UnexpectedEnvelope("terminal attachment has no lease".into()))?
            .to_owned();
        wire::decode_exact(
            &self.inner.connection_control(
                ops::TERMINAL_VIEWER_RESIZE,
                Params::new()
                    .string(field::ATTACHMENT_LEASE, attachment_lease)
                    .u16(field::COLS, size.cols)
                    .u16(field::ROWS, size.rows),
            )?,
            "terminal viewer resize result",
        )
    }

    pub fn release(&mut self) -> Result<super::model::ViewerReleaseResult> {
        let attachment_lease = self
            .inner
            .attachment_lease()
            .ok_or_else(|| Error::UnexpectedEnvelope("terminal attachment has no lease".into()))?
            .to_owned();
        wire::decode_exact(
            &self.inner.connection_control(
                ops::TERMINAL_VIEWER_RELEASE,
                Params::new().string(field::ATTACHMENT_LEASE, attachment_lease),
            )?,
            "terminal viewer release result",
        )
    }

    pub fn viewer_resize(&mut self, size: Size) -> Result<super::model::ViewerResizeResult> {
        self.resize(size)
    }

    pub fn viewer_release(&mut self) -> Result<super::model::ViewerReleaseResult> {
        self.release()
    }
}

impl BrowserAttachment {
    /// Updates the viewer lease on this attachment's owned stream connection.
    pub fn resize(&mut self, size: PixelSize) -> Result<super::model::BrowserViewerResizeResult> {
        wire::validate_pixel_size(size)?;
        let attachment_lease = self
            .inner
            .attachment_lease()
            .ok_or_else(|| Error::UnexpectedEnvelope("browser attachment has no lease".into()))?
            .to_owned();
        wire::decode_exact(
            &self.inner.connection_control(
                ops::BROWSER_VIEWER_RESIZE,
                Params::new()
                    .string(field::ATTACHMENT_LEASE, attachment_lease)
                    .u32(field::WIDTH_PX, size.width_px)
                    .u32(field::HEIGHT_PX, size.height_px),
            )?,
            "browser viewer resize result",
        )
    }

    pub fn release(&mut self) -> Result<super::model::ViewerReleaseResult> {
        let attachment_lease = self
            .inner
            .attachment_lease()
            .ok_or_else(|| Error::UnexpectedEnvelope("browser attachment has no lease".into()))?
            .to_owned();
        wire::decode_exact(
            &self.inner.connection_control(
                ops::BROWSER_VIEWER_RELEASE,
                Params::new().string(field::ATTACHMENT_LEASE, attachment_lease),
            )?,
            "browser viewer release result",
        )
    }

    pub fn viewer_resize(
        &mut self,
        size: PixelSize,
    ) -> Result<super::model::BrowserViewerResizeResult> {
        self.resize(size)
    }

    pub fn viewer_release(&mut self) -> Result<super::model::ViewerReleaseResult> {
        self.release()
    }
}

fn decode_session_event(
    value: Value,
    envelope_cursor: Option<Cursor>,
    _sequence: u64,
) -> Result<SessionEvent> {
    let raw = value.clone();
    let mut object = object(value, "session event")?;
    let kind = take_required_string(&mut object, "kind")?;
    match kind.as_str() {
        "snapshot" => {
            let cursor = take_cursor(&mut object)?;
            validate_envelope_cursor(envelope_cursor.as_ref(), &cursor)?;
            let reset_reason = match take_optional_string(&mut object, "reset_reason")?.as_deref() {
                None => None,
                Some("initial") => Some(ResetReason::Initial),
                Some("generation_changed") => Some(ResetReason::GenerationChanged),
                Some("cursor_expired") => Some(ResetReason::CursorExpired),
                Some(other) => {
                    return Err(Error::UnexpectedEnvelope(format!(
                        "invalid session reset_reason {other}"
                    )));
                }
            };
            let snapshot =
                wire::decode_exact(&take_required(&mut object, "snapshot")?, "resource snapshot")?;
            finish(object, "session snapshot item")?;
            Ok(SessionEvent::Snapshot(SessionSnapshotEvent { cursor, reset_reason, snapshot }))
        }
        "delta" => {
            let cursor = take_cursor(&mut object)?;
            validate_envelope_cursor(envelope_cursor.as_ref(), &cursor)?;
            let previous_revision = take_decimal(&mut object, "previous_revision")?;
            let revision = take_decimal(&mut object, "revision")?;
            if revision != cursor.revision {
                return Err(Error::UnexpectedEnvelope(
                    "session delta revision must equal cursor revision".to_string(),
                ));
            }
            let changes = take_array(&mut object, "changes")?
                .into_iter()
                .map(decode_resource_change)
                .collect::<Result<Vec<_>>>()?;
            finish(object, "session delta item")?;
            Ok(SessionEvent::Delta(SessionDeltaEvent {
                cursor,
                previous_revision,
                revision,
                changes,
            }))
        }
        _ => Ok(SessionEvent::Unknown { kind, raw: Document(raw) }),
    }
}

fn decode_session_journal_record(
    value: Value,
    envelope_cursor: Option<Cursor>,
    _stream_sequence: u64,
) -> Result<SessionJournalRecord> {
    let mut object = object(value, "session journal record")?;
    let sequence = take_decimal(&mut object, "sequence")?;
    let cursor = envelope_cursor.ok_or_else(|| {
        Error::UnexpectedEnvelope("journal stream item requires a cursor".to_string())
    })?;
    if cursor.revision != sequence {
        return Err(Error::UnexpectedEnvelope(
            "journal sequence must equal its stream cursor revision".to_string(),
        ));
    }
    let event_id = take_required_string(&mut object, "event_id")?;
    let schema_version = take_u32(&mut object, "schema_version")?;
    let kind = take_required_string(&mut object, "kind")?;
    if event_id.is_empty() || schema_version == 0 || kind.is_empty() {
        return Err(Error::UnexpectedEnvelope(
            "journal event_id and kind must be non-empty and schema_version must be positive"
                .to_string(),
        ));
    }
    let class = match take_required_string(&mut object, "class")?.as_str() {
        "state" => JournalClass::State,
        "observation" => JournalClass::Observation,
        "effect" => JournalClass::Effect,
        "checkpoint" => JournalClass::Checkpoint,
        value => {
            return Err(Error::UnexpectedEnvelope(format!("invalid journal class {value}")));
        }
    };
    let replay = match take_required_string(&mut object, "replay")?.as_str() {
        "required" => JournalReplayPolicy::Required,
        "advisory" => JournalReplayPolicy::Advisory,
        "never" => JournalReplayPolicy::Never,
        value => {
            return Err(Error::UnexpectedEnvelope(format!(
                "invalid journal replay policy {value}"
            )));
        }
    };
    let occurred_at_ms = take_decimal(&mut object, "occurred_at_ms")?;
    let committed_at_ms = take_decimal(&mut object, "committed_at_ms")?;
    let producer = decode_journal_producer(take_required(&mut object, "producer")?)?;
    let authority = match take_required(&mut object, "authority")? {
        Value::Null => None,
        value => Some(decode_journal_authority(value)?),
    };
    let causation_id = take_required_nullable_string(&mut object, "causation_id")?;
    let correlation_id = take_required_nullable_string(&mut object, "correlation_id")?;
    let causation_depth = take_u16(&mut object, "causation_depth")?;
    let subjects = take_array(&mut object, "subjects")?
        .into_iter()
        .map(decode_journal_subject)
        .collect::<Result<Vec<_>>>()?;
    let sensitivity = match take_required_string(&mut object, "sensitivity")?.as_str() {
        "public" => JournalSensitivity::Public,
        "metadata" => JournalSensitivity::Metadata,
        "sensitive" => JournalSensitivity::Sensitive,
        "secret" => JournalSensitivity::Secret,
        value => {
            return Err(Error::UnexpectedEnvelope(format!("invalid journal sensitivity {value}")));
        }
    };
    let payload = take_required(&mut object, "payload")?;
    let resource_revision = take_nullable_decimal(&mut object, "resource_revision")?;
    let previous_resource_revision =
        take_nullable_decimal(&mut object, "previous_resource_revision")?;
    finish(object, "session journal record")?;
    Ok(SessionJournalRecord {
        sequence,
        event_id,
        schema_version,
        kind,
        class,
        replay,
        occurred_at_ms,
        committed_at_ms,
        producer,
        authority,
        causation_id,
        correlation_id,
        causation_depth,
        subjects,
        sensitivity,
        payload,
        resource_revision,
        previous_resource_revision,
    })
}

fn decode_journal_producer(value: Value) -> Result<JournalProducer> {
    let mut object = object(value, "journal producer")?;
    let kind = take_required_string(&mut object, "kind")?;
    let id = take_required_string(&mut object, "id")?;
    finish(object, "journal producer")?;
    if kind.is_empty() || id.is_empty() {
        return Err(Error::UnexpectedEnvelope(
            "journal producer kind and id must be non-empty".to_string(),
        ));
    }
    Ok(JournalProducer { kind, id })
}

fn decode_journal_authority(value: Value) -> Result<JournalAuthority> {
    let mut object = object(value, "journal authority")?;
    let principal_id = take_required_string(&mut object, "principal_id")?;
    let lease_id = take_required_string(&mut object, "lease_id")?;
    let generation = take_required_string(&mut object, "generation")?;
    let role = take_required_string(&mut object, "role")?;
    finish(object, "journal authority")?;
    if [principal_id.as_str(), lease_id.as_str(), generation.as_str(), role.as_str()].contains(&"")
    {
        return Err(Error::UnexpectedEnvelope(
            "journal authority fields must be non-empty".to_string(),
        ));
    }
    Ok(JournalAuthority { principal_id, lease_id, generation, role })
}

fn decode_journal_subject(value: Value) -> Result<JournalSubject> {
    let mut object = object(value, "journal subject")?;
    let kind = take_required_string(&mut object, "kind")?;
    let id = take_required_string(&mut object, "id")?;
    finish(object, "journal subject")?;
    if kind.is_empty() || id.is_empty() {
        return Err(Error::UnexpectedEnvelope(
            "journal subject kind and id must be non-empty".to_string(),
        ));
    }
    Ok(JournalSubject { kind, id })
}

fn decode_resource_change(value: Value) -> Result<ResourceChange> {
    let raw = value.clone();
    let mut object = object(value, "resource change")?;
    let kind = take_required_string(&mut object, "kind")?;
    match kind.as_str() {
        "upsert" => {
            let sequence = take_u32(&mut object, "sequence")?;
            let resource = ResourceKind::parse(&take_required_string(&mut object, "resource")?)?;
            let id = parse_resource_id(resource, &take_required_string(&mut object, "id")?)?;
            let value = take_required(&mut object, "value")?;
            if value.get("id").and_then(Value::as_str) != Some(id.as_str()) {
                return Err(Error::UnexpectedEnvelope(
                    "resource upsert value ID does not match change ID".to_string(),
                ));
            }
            let value = decode_resource_entity(resource, &value)?;
            finish(object, "resource upsert")?;
            Ok(ResourceChange::Upsert { sequence, resource, id, value })
        }
        "delete" => {
            let sequence = take_u32(&mut object, "sequence")?;
            let resource = ResourceKind::parse(&take_required_string(&mut object, "resource")?)?;
            let id = parse_resource_id(resource, &take_required_string(&mut object, "id")?)?;
            finish(object, "resource delete")?;
            Ok(ResourceChange::Delete { sequence, resource, id })
        }
        _ => Ok(ResourceChange::Unknown { kind, raw: Document(raw) }),
    }
}

fn decode_terminal_item(
    value: Value,
    _cursor: Option<Cursor>,
    _sequence: u64,
) -> Result<TerminalAttachmentItem> {
    let raw = value.clone();
    let mut object = object(value, "terminal attachment item")?;
    let kind = take_required_string(&mut object, "kind")?;
    match kind.as_str() {
        "snapshot" => {
            let terminal_id = take_id(&mut object, "terminal_id")?;
            let render = decode_render_snapshot(take_required(&mut object, "render")?)?;
            finish(object, "terminal snapshot item")?;
            Ok(TerminalAttachmentItem::Snapshot { terminal_id, render })
        }
        "patch" => {
            let terminal_id = take_id(&mut object, "terminal_id")?;
            let render = decode_render_patch(take_required(&mut object, "render")?)?;
            finish(object, "terminal patch item")?;
            Ok(TerminalAttachmentItem::Patch { terminal_id, render })
        }
        "scroll" => {
            let terminal_id = take_id(&mut object, "terminal_id")?;
            let scroll = decode_render_scroll(take_required(&mut object, "scroll")?)?;
            finish(object, "terminal scroll item")?;
            Ok(TerminalAttachmentItem::Scroll { terminal_id, scroll })
        }
        _ => Ok(TerminalAttachmentItem::Unknown { kind, raw: Document(raw) }),
    }
}

fn decode_browser_item(
    value: Value,
    _cursor: Option<Cursor>,
    _sequence: u64,
) -> Result<BrowserAttachmentItem> {
    let raw = value.clone();
    let mut object = object(value, "browser attachment item")?;
    let kind = take_required_string(&mut object, "kind")?;
    match kind.as_str() {
        "snapshot" => {
            let browser = wire::snapshot::<BrowserSnapshot>(
                &take_required(&mut object, "browser")?,
                "browser",
            )?;
            let size = decode_pixel_size(take_required(&mut object, "size")?)?;
            finish(object, "browser snapshot item")?;
            Ok(BrowserAttachmentItem::Snapshot { browser, size })
        }
        "frame" => {
            let mime_type = match take_required_string(&mut object, "mime_type")?.as_str() {
                "image/png" => BrowserFrameMime::Png,
                "image/jpeg" => BrowserFrameMime::Jpeg,
                other => {
                    return Err(Error::UnexpectedEnvelope(format!(
                        "invalid browser frame MIME type {other}"
                    )));
                }
            };
            let data = take_base64(&mut object, "data_base64")?;
            let size = PixelSize {
                width_px: take_u32(&mut object, "width_px")?,
                height_px: take_u32(&mut object, "height_px")?,
            };
            if size.width_px == 0 || size.height_px == 0 {
                return Err(Error::UnexpectedEnvelope(
                    "browser frame pixel dimensions must be greater than zero".to_string(),
                ));
            }
            let pointer_frame_seq = take_nullable_decimal(&mut object, "pointer_frame_seq")?;
            finish(object, "browser frame item")?;
            Ok(BrowserAttachmentItem::Frame { mime_type, data, size, pointer_frame_seq })
        }
        "state" => {
            let url = take_required_string(&mut object, "url")?;
            let title = take_required_string(&mut object, "title")?;
            let loading = take_bool(&mut object, "loading")?;
            finish(object, "browser state item")?;
            Ok(BrowserAttachmentItem::State { url, title, loading })
        }
        _ => Ok(BrowserAttachmentItem::Unknown { kind, raw: Document(raw) }),
    }
}

fn decode_sidebar_item(
    value: Value,
    _cursor: Option<Cursor>,
    _sequence: u64,
) -> Result<SidebarViewItem> {
    let raw = value.clone();
    let mut object = object(value, "sidebar attachment item")?;
    let kind = take_required_string(&mut object, "kind")?;
    match kind.as_str() {
        "snapshot" => {
            let sidebar_view = wire::snapshot::<SidebarViewSnapshot>(
                &take_required(&mut object, "sidebar_view")?,
                "sidebar_view",
            )?;
            let render = decode_render_snapshot(take_required(&mut object, "render")?)?;
            finish(object, "sidebar snapshot item")?;
            Ok(SidebarViewItem::Snapshot { sidebar_view, render })
        }
        "patch" => {
            let sidebar_view_id = take_id(&mut object, "sidebar_view_id")?;
            let render = decode_render_patch(take_required(&mut object, "render")?)?;
            finish(object, "sidebar patch item")?;
            Ok(SidebarViewItem::Patch { sidebar_view_id, render })
        }
        "scroll" => {
            let sidebar_view_id = take_id(&mut object, "sidebar_view_id")?;
            let scroll = decode_render_scroll(take_required(&mut object, "scroll")?)?;
            finish(object, "sidebar scroll item")?;
            Ok(SidebarViewItem::Scroll { sidebar_view_id, scroll })
        }
        _ => Ok(SidebarViewItem::Unknown { kind, raw: Document(raw) }),
    }
}

fn decode_render_snapshot(value: Value) -> Result<RenderSnapshot> {
    let mut object = object(value, "render snapshot")?;
    let size = decode_size(take_required(&mut object, "size")?)?;
    let cursor = decode_render_cursor(take_required(&mut object, "cursor")?)?;
    let default_fg = take_color(&mut object, "default_fg")?;
    let default_bg = take_color(&mut object, "default_bg")?;
    let scrollback_rows = take_u32(&mut object, "scrollback_rows")?;
    let rows = take_array(&mut object, "rows")?
        .into_iter()
        .map(decode_render_row)
        .collect::<Result<Vec<_>>>()?;
    if rows.len() != usize::from(size.rows) {
        return Err(Error::UnexpectedEnvelope(
            "render snapshot rows must equal size.rows".to_string(),
        ));
    }
    let mut row_indexes = rows.iter().map(|row| row.row).collect::<Vec<_>>();
    row_indexes.sort_unstable();
    if row_indexes != (0..size.rows).collect::<Vec<_>>() {
        return Err(Error::UnexpectedEnvelope(
            "render snapshot must contain each viewport row exactly once".to_string(),
        ));
    }
    finish(object, "render snapshot")?;
    Ok(RenderSnapshot { size, cursor, default_fg, default_bg, scrollback_rows, rows })
}

fn decode_render_patch(value: Value) -> Result<RenderPatch> {
    let mut object = object(value, "render patch")?;
    let cursor = decode_render_cursor(take_required(&mut object, "cursor")?)?;
    let full_reset = take_bool(&mut object, "full_reset")?;
    let size = take_optional(&mut object, "size").map(decode_size).transpose()?;
    let default_fg = take_optional(&mut object, "default_fg").map(parse_color_value).transpose()?;
    let default_bg = take_optional(&mut object, "default_bg").map(parse_color_value).transpose()?;
    let scrollback_rows = take_optional(&mut object, "scrollback_rows")
        .map(|value| parse_u32_value(&value, "scrollback_rows"))
        .transpose()?;
    let rows = take_array(&mut object, "rows")?
        .into_iter()
        .map(decode_render_row)
        .collect::<Result<Vec<_>>>()?;
    if size.is_some() && !full_reset {
        return Err(Error::UnexpectedEnvelope(
            "render resize patch must be a full reset".to_string(),
        ));
    }
    if let Some(size) = size
        && rows.len() != usize::from(size.rows)
    {
        return Err(Error::UnexpectedEnvelope(
            "render resize patch rows must equal size.rows".to_string(),
        ));
    }
    finish(object, "render patch")?;
    Ok(RenderPatch { cursor, full_reset, size, default_fg, default_bg, scrollback_rows, rows })
}

fn decode_render_scroll(value: Value) -> Result<RenderScroll> {
    let mut object = object(value, "render scroll")?;
    let offset = take_decimal(&mut object, "offset")?;
    let at_bottom = take_bool(&mut object, "at_bottom")?;
    finish(object, "render scroll")?;
    Ok(RenderScroll { offset, at_bottom })
}

fn decode_render_cursor(value: Value) -> Result<RenderCursor> {
    let mut object = object(value, "render cursor")?;
    let x = take_u16(&mut object, "x")?;
    let y = take_u16(&mut object, "y")?;
    let style = match take_required_string(&mut object, "style")?.as_str() {
        "block" => RenderCursorStyle::Block,
        "underline" => RenderCursorStyle::Underline,
        "bar" => RenderCursorStyle::Bar,
        other => {
            return Err(Error::UnexpectedEnvelope(format!("invalid render cursor style {other}")));
        }
    };
    let blink = take_bool(&mut object, "blink")?;
    let visible = take_bool(&mut object, "visible")?;
    let color = take_nullable_color(&mut object, "color")?;
    finish(object, "render cursor")?;
    Ok(RenderCursor { x, y, style, blink, visible, color })
}

pub(crate) fn decode_render_row(value: Value) -> Result<RenderRow> {
    let mut object = object(value, "render row")?;
    let row = take_u16(&mut object, "row")?;
    let runs = take_array(&mut object, "runs")?
        .into_iter()
        .map(decode_render_run)
        .collect::<Result<Vec<_>>>()?;
    finish(object, "render row")?;
    Ok(RenderRow { row, runs })
}

fn decode_render_run(value: Value) -> Result<RenderRun> {
    let mut object = object(value, "render run")?;
    let text = take_required_string(&mut object, "text")?;
    let fg = take_nullable_color(&mut object, "fg")?;
    let bg = take_nullable_color(&mut object, "bg")?;
    let attrs = take_u32(&mut object, "attrs")?;
    let underline = match take_optional_string(&mut object, "underline")?.as_deref() {
        None => None,
        Some("single") => Some(RenderUnderline::Single),
        Some("double") => Some(RenderUnderline::Double),
        Some("curly") => Some(RenderUnderline::Curly),
        Some("dotted") => Some(RenderUnderline::Dotted),
        Some("dashed") => Some(RenderUnderline::Dashed),
        Some(other) => {
            return Err(Error::UnexpectedEnvelope(format!("invalid render underline {other}")));
        }
    };
    let width_hint = take_optional(&mut object, "width_hint")
        .map(|value| parse_u16_value(&value, "width_hint"))
        .transpose()?;
    finish(object, "render run")?;
    Ok(RenderRun { text, fg, bg, attrs, underline, width_hint })
}

fn decode_size(value: Value) -> Result<Size> {
    let mut object = object(value, "size")?;
    let size = Size { cols: take_u16(&mut object, "cols")?, rows: take_u16(&mut object, "rows")? };
    if size.cols == 0 || size.rows == 0 {
        return Err(Error::UnexpectedEnvelope(
            "size dimensions must be greater than zero".to_string(),
        ));
    }
    finish(object, "size")?;
    Ok(size)
}

fn decode_pixel_size(value: Value) -> Result<PixelSize> {
    let mut object = object(value, "pixel size")?;
    let size = PixelSize {
        width_px: take_u32(&mut object, "width_px")?,
        height_px: take_u32(&mut object, "height_px")?,
    };
    if size.width_px == 0 || size.height_px == 0 {
        return Err(Error::UnexpectedEnvelope(
            "pixel dimensions must be greater than zero".to_string(),
        ));
    }
    finish(object, "pixel size")?;
    Ok(size)
}

fn decode_resource_entity(resource: ResourceKind, value: &Value) -> Result<ResourceEntitySnapshot> {
    Ok(match resource {
        ResourceKind::Machine => {
            ResourceEntitySnapshot::Machine(wire::snapshot::<MachineSnapshot>(value, "machine")?)
        }
        ResourceKind::Session => {
            ResourceEntitySnapshot::Session(wire::snapshot::<SessionSnapshot>(value, "session")?)
        }
        ResourceKind::Workspace => ResourceEntitySnapshot::Workspace(wire::snapshot::<
            WorkspaceSnapshot,
        >(value, "workspace")?),
        ResourceKind::Screen => {
            ResourceEntitySnapshot::Screen(wire::snapshot::<ScreenSnapshot>(value, "screen")?)
        }
        ResourceKind::Pane => {
            ResourceEntitySnapshot::Pane(wire::snapshot::<PaneSnapshot>(value, "pane")?)
        }
        ResourceKind::Tab => {
            ResourceEntitySnapshot::Tab(wire::snapshot::<TabSnapshot>(value, "tab")?)
        }
        ResourceKind::Terminal => {
            ResourceEntitySnapshot::Terminal(wire::snapshot::<TerminalSnapshot>(value, "terminal")?)
        }
        ResourceKind::Browser => {
            ResourceEntitySnapshot::Browser(wire::snapshot::<BrowserSnapshot>(value, "browser")?)
        }
        ResourceKind::Client => {
            ResourceEntitySnapshot::Client(wire::snapshot::<ClientSnapshot>(value, "client")?)
        }
        ResourceKind::Notification => {
            ResourceEntitySnapshot::Notification(wire::snapshot::<NotificationSnapshot>(
                value,
                "notification",
            )?)
        }
        ResourceKind::Agent => {
            ResourceEntitySnapshot::Agent(wire::snapshot::<AgentSnapshot>(value, "agent")?)
        }
        ResourceKind::PairingRequest => {
            ResourceEntitySnapshot::PairingRequest(wire::snapshot::<PairingRequestSnapshot>(
                value,
                "pairing_request",
            )?)
        }
        ResourceKind::FrontendProjection => ResourceEntitySnapshot::FrontendProjection(
            wire::snapshot::<FrontendProjectionSnapshot>(value, "frontend_projection")?,
        ),
        ResourceKind::SidebarView => ResourceEntitySnapshot::SidebarView(wire::snapshot::<
            SidebarViewSnapshot,
        >(
            value, "sidebar_view"
        )?),
    })
}

fn parse_resource_id(kind: ResourceKind, id: &str) -> Result<ResourceReference> {
    let id = id.to_string();
    Ok(match kind {
        ResourceKind::Machine => ResourceReference::Machine(MachineId::parse(id)?),
        ResourceKind::Session => ResourceReference::Session(SessionId::parse(id)?),
        ResourceKind::Workspace => ResourceReference::Workspace(WorkspaceId::parse(id)?),
        ResourceKind::Screen => ResourceReference::Screen(ScreenId::parse(id)?),
        ResourceKind::Pane => ResourceReference::Pane(PaneId::parse(id)?),
        ResourceKind::Tab => ResourceReference::Tab(TabId::parse(id)?),
        ResourceKind::Terminal => ResourceReference::Terminal(TerminalId::parse(id)?),
        ResourceKind::Browser => ResourceReference::Browser(BrowserId::parse(id)?),
        ResourceKind::Client => ResourceReference::Client(ConnectedClientId::parse(id)?),
        ResourceKind::Notification => ResourceReference::Notification(NotificationId::parse(id)?),
        ResourceKind::Agent => ResourceReference::Agent(AgentId::parse(id)?),
        ResourceKind::PairingRequest => {
            ResourceReference::PairingRequest(PairingRequestId::parse(id)?)
        }
        ResourceKind::FrontendProjection => {
            ResourceReference::FrontendProjection(FrontendProjectionId::parse(id)?)
        }
        ResourceKind::SidebarView => ResourceReference::SidebarView(SidebarViewId::parse(id)?),
    })
}

fn object(value: Value, context: &str) -> Result<Map<String, Value>> {
    value
        .as_object()
        .cloned()
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("{context} must be an object")))
}

fn finish(object: Map<String, Value>, context: &str) -> Result<()> {
    if object.is_empty() {
        Ok(())
    } else {
        Err(Error::UnexpectedEnvelope(format!(
            "{context} contains unknown fields: {}",
            object.keys().cloned().collect::<Vec<_>>().join(", ")
        )))
    }
}

fn take_required(object: &mut Map<String, Value>, key: &str) -> Result<Value> {
    object.remove(key).ok_or_else(|| Error::UnexpectedEnvelope(format!("{key} is required")))
}

fn take_optional(object: &mut Map<String, Value>, key: &str) -> Option<Value> {
    object.remove(key)
}

fn take_required_string(object: &mut Map<String, Value>, key: &str) -> Result<String> {
    match take_required(object, key)? {
        Value::String(value) => Ok(value),
        _ => Err(Error::UnexpectedEnvelope(format!("{key} must be a string"))),
    }
}

fn take_optional_string(object: &mut Map<String, Value>, key: &str) -> Result<Option<String>> {
    match object.remove(key) {
        None => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(Error::UnexpectedEnvelope(format!("{key} must be a string"))),
    }
}

fn take_required_nullable_string(
    object: &mut Map<String, Value>,
    key: &str,
) -> Result<Option<String>> {
    match take_required(object, key)? {
        Value::Null => Ok(None),
        Value::String(value) => Ok(Some(value)),
        _ => Err(Error::UnexpectedEnvelope(format!("{key} must be a string or null"))),
    }
}

fn take_bool(object: &mut Map<String, Value>, key: &str) -> Result<bool> {
    take_required(object, key)?
        .as_bool()
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("{key} must be a boolean")))
}

fn take_u16(object: &mut Map<String, Value>, key: &str) -> Result<u16> {
    parse_u16_value(&take_required(object, key)?, key)
}

fn parse_u16_value(value: &Value, key: &str) -> Result<u16> {
    value
        .as_u64()
        .and_then(|value| u16::try_from(value).ok())
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("{key} must be a uint16")))
}

fn take_u32(object: &mut Map<String, Value>, key: &str) -> Result<u32> {
    parse_u32_value(&take_required(object, key)?, key)
}

fn parse_u32_value(value: &Value, key: &str) -> Result<u32> {
    value
        .as_u64()
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("{key} must be a uint32")))
}

fn take_decimal(object: &mut Map<String, Value>, key: &str) -> Result<u64> {
    wire::parse_decimal(&take_required(object, key)?, key)
}

fn take_nullable_decimal(object: &mut Map<String, Value>, key: &str) -> Result<Option<u64>> {
    match take_required(object, key)? {
        Value::Null => Ok(None),
        value => wire::parse_decimal(&value, key).map(Some),
    }
}

fn take_array(object: &mut Map<String, Value>, key: &str) -> Result<Vec<Value>> {
    take_required(object, key)?
        .as_array()
        .cloned()
        .ok_or_else(|| Error::UnexpectedEnvelope(format!("{key} must be an array")))
}

fn take_cursor(object: &mut Map<String, Value>) -> Result<Cursor> {
    wire::parse_cursor(&take_required(object, "cursor")?)
}

fn validate_envelope_cursor(envelope: Option<&Cursor>, item: &Cursor) -> Result<()> {
    if envelope.is_some_and(|envelope| envelope != item) {
        return Err(Error::UnexpectedEnvelope(
            "stream envelope and item cursors differ".to_string(),
        ));
    }
    Ok(())
}

fn take_id<I: OpaqueId>(object: &mut Map<String, Value>, key: &str) -> Result<I> {
    I::parse(take_required_string(object, key)?)
}

fn take_color(object: &mut Map<String, Value>, key: &str) -> Result<ColorHex> {
    parse_wire_color(&take_required_string(object, key)?)
}

fn parse_color_value(value: Value) -> Result<ColorHex> {
    let value = value
        .as_str()
        .ok_or_else(|| Error::UnexpectedEnvelope("color must be a string".to_string()))?;
    parse_wire_color(value)
}

fn take_nullable_color(object: &mut Map<String, Value>, key: &str) -> Result<Option<ColorHex>> {
    match take_required(object, key)? {
        Value::Null => Ok(None),
        Value::String(value) => parse_wire_color(&value).map(Some),
        _ => Err(Error::UnexpectedEnvelope(format!("{key} must be a color or null"))),
    }
}

fn parse_wire_color(value: &str) -> Result<ColorHex> {
    if !valid_color(value) {
        return Err(Error::UnexpectedEnvelope("color must be lowercase #rrggbb".to_string()));
    }
    Ok(ColorHex(value.to_string()))
}

fn take_base64(object: &mut Map<String, Value>, key: &str) -> Result<Vec<u8>> {
    let encoded = take_required_string(object, key)?;
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|error| Error::Decode(format!("invalid {key}: {error}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TERMINAL: &str = "term_00000000000000000000000000000001";

    fn cursor() -> Value {
        json!({
            "x": 1,
            "y": 0,
            "style": "block",
            "blink": false,
            "visible": true,
            "color": null
        })
    }

    fn row(row: u16, text: &str) -> Value {
        json!({
            "row": row,
            "runs": [{
                "text": text,
                "fg": null,
                "bg": null,
                "attrs": RenderRun::ATTR_BOLD,
                "underline": "single",
                "width_hint": text.len()
            }]
        })
    }

    #[test]
    fn terminal_render_snapshot_decodes_without_a_vt_emulator() {
        let item = decode_terminal_item(
            json!({
                "kind": "snapshot",
                "terminal_id": TERMINAL,
                "render": {
                    "size": {"cols": 4, "rows": 2},
                    "cursor": cursor(),
                    "default_fg": "#ffffff",
                    "default_bg": "#000000",
                    "scrollback_rows": 7,
                    "rows": [row(0, "one"), row(1, "two")]
                }
            }),
            None,
            0,
        )
        .unwrap();
        let TerminalAttachmentItem::Snapshot { render, .. } = item else {
            panic!("expected snapshot");
        };
        assert_eq!(render.size, Size { cols: 4, rows: 2 });
        assert_eq!(render.rows[1].runs[0].text, "two");
        assert!(render.rows[0].runs[0].has_attr(RenderRun::ATTR_BOLD));
    }

    #[test]
    fn unknown_variants_preserve_the_complete_raw_object() {
        let item = decode_terminal_item(
            json!({"kind": "future", "terminal_id": TERMINAL, "opaque": {"x": 1}}),
            None,
            3,
        )
        .unwrap();
        let TerminalAttachmentItem::Unknown { kind, raw } = item else {
            panic!("expected unknown");
        };
        assert_eq!(kind, "future");
        let raw: Value = raw.deserialize().unwrap();
        assert_eq!(raw["opaque"]["x"], 1);
        assert_eq!(raw["kind"], "future");
    }

    #[test]
    fn malformed_known_variants_are_decode_errors() {
        let error =
            decode_terminal_item(json!({"kind": "snapshot", "terminal_id": TERMINAL}), None, 0)
                .unwrap_err();
        assert!(matches!(error, Error::UnexpectedEnvelope(_)));
    }

    #[test]
    fn browser_frames_require_nullable_decimal_pointer_authority() {
        for (value, expected) in
            [(json!(null), None), (json!("18446744073709551615"), Some(u64::MAX))]
        {
            let item = decode_browser_item(
                json!({
                    "kind": "frame",
                    "mime_type": "image/png",
                    "data_base64": "AA==",
                    "width_px": 1,
                    "height_px": 1,
                    "pointer_frame_seq": value
                }),
                None,
                0,
            )
            .unwrap();
            let BrowserAttachmentItem::Frame { pointer_frame_seq, .. } = item else {
                panic!("expected frame");
            };
            assert_eq!(pointer_frame_seq, expected);
        }

        for invalid in [
            json!({
                "kind": "frame",
                "mime_type": "image/png",
                "data_base64": "AA==",
                "width_px": 1,
                "height_px": 1
            }),
            json!({
                "kind": "frame",
                "mime_type": "image/png",
                "data_base64": "AA==",
                "width_px": 1,
                "height_px": 1,
                "pointer_frame_seq": 7
            }),
            json!({
                "kind": "frame",
                "mime_type": "image/png",
                "data_base64": "AA==",
                "width_px": 1,
                "height_px": 1,
                "pointer_frame_seq": "07"
            }),
        ] {
            assert!(matches!(
                decode_browser_item(invalid, None, 0),
                Err(Error::UnexpectedEnvelope(_))
            ));
        }
    }

    #[test]
    fn known_resource_upserts_reject_unknown_snapshot_siblings() {
        let error = decode_resource_change(json!({
            "kind": "upsert",
            "sequence": 1,
            "resource": "terminal",
            "id": TERMINAL,
            "value": {
                "id": TERMINAL,
                "tab_id": "tab_00000000000000000000000000000002",
                "tab_ids": ["tab_00000000000000000000000000000002"],
                "title": "strict",
                "cols": 80,
                "rows": 24,
                "running": true,
                "lifecycle": "running",
                "future": "must use extra"
            }
        }))
        .unwrap_err();
        assert!(matches!(error, Error::UnexpectedEnvelope(_)));
    }
}

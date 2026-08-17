use super::id::*;
use super::options::{AgentState, CopyMode, CursorStyle, NotificationLevel, PixelSize, Size};
use super::typed_stream::RenderRow;
use base64::Engine;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// JSON retained only where the catalog explicitly declares a JSON or extension value.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(transparent)]
pub struct Document(pub(crate) Value);

impl Document {
    /// Decodes the document into a caller-selected type.
    pub fn deserialize<T: DeserializeOwned>(&self) -> crate::Result<T> {
        serde_json::from_value(self.0.clone())
            .map_err(|error| crate::Error::Decode(error.to_string()))
    }

    /// Encodes a caller-selected type as a document.
    pub fn from_serializable<T: Serialize>(value: &T) -> crate::Result<Self> {
        serde_json::to_value(value)
            .map(Self)
            .map_err(|error| crate::Error::Decode(error.to_string()))
    }
}

/// Origin of a machine visible to cmux.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineOrigin {
    Local,
}

/// Current lifecycle state of a machine.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MachineStatus {
    Running,
    Connecting,
    Sleeping,
    Stopped,
    Unavailable,
}

/// Catalog snapshot for one machine.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MachineSnapshot {
    pub id: MachineId,
    pub name: String,
    pub origin: MachineOrigin,
    pub status: MachineStatus,
    pub connectable: bool,
    pub deleted: bool,
    pub recoverable: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Catalog snapshot for one session.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SessionSnapshot {
    pub id: SessionId,
    pub machine_id: MachineId,
    #[serde(default, deserialize_with = "deserialize_optional_non_null")]
    pub name: Option<String>,
    #[serde(deserialize_with = "deserialize_generation")]
    pub generation: String,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    pub connected: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Catalog snapshot for one workspace.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WorkspaceSnapshot {
    pub id: WorkspaceId,
    pub session_id: SessionId,
    pub name: String,
    pub index: u32,
    pub focused: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Direction of a stable layout split.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LayoutDirection {
    Horizontal,
    Vertical,
}

/// One pane and its ordered tabs in a layout document.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutLeaf {
    pub pane_id: PaneId,
    pub tab_ids: Vec<TabId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_tab_id: Option<TabId>,
}

/// Two recursively nested layout nodes separated by one stable split.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutSplit {
    pub split_id: SplitId,
    pub direction: LayoutDirection,
    pub ratio: f64,
    pub first: Box<LayoutNode>,
    pub second: Box<LayoutNode>,
}

impl<'de> Deserialize<'de> for LayoutSplit {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            split_id: SplitId,
            direction: LayoutDirection,
            ratio: f64,
            first: Box<LayoutNode>,
            second: Box<LayoutNode>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !wire.ratio.is_finite() || wire.ratio <= 0.0 || wire.ratio >= 1.0 {
            return Err(serde::de::Error::custom(
                "layout split ratio must be finite and between zero and one",
            ));
        }
        Ok(Self {
            split_id: wire.split_id,
            direction: wire.direction,
            ratio: wire.ratio,
            first: wire.first,
            second: wire.second,
        })
    }
}

/// Ordered panes collapsed into one stack.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutStack {
    pub pane_ids: Vec<PaneId>,
    pub expanded_pane_id: PaneId,
}

impl<'de> Deserialize<'de> for LayoutStack {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            pane_ids: Vec<PaneId>,
            expanded_pane_id: PaneId,
        }

        let wire = Wire::deserialize(deserializer)?;
        if wire.pane_ids.is_empty() {
            return Err(serde::de::Error::custom("layout stack must contain at least one pane"));
        }
        if !wire.pane_ids.contains(&wire.expanded_pane_id) {
            return Err(serde::de::Error::custom(
                "layout stack expanded pane must be a stack member",
            ));
        }
        Ok(Self { pane_ids: wire.pane_ids, expanded_pane_id: wire.expanded_pane_id })
    }
}

/// One stable horizontal viewport column.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutColumn {
    pub column_id: SplitId,
    pub width: f64,
    pub root: Box<LayoutNode>,
}

impl<'de> Deserialize<'de> for LayoutColumn {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            column_id: SplitId,
            width: f64,
            root: Box<LayoutNode>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !wire.width.is_finite() || !(0.1..=1.0).contains(&wire.width) {
            return Err(serde::de::Error::custom(
                "layout column width must be finite and between 0.1 and 1",
            ));
        }
        Ok(Self { column_id: wire.column_id, width: wire.width, root: wire.root })
    }
}

/// Horizontally scrolling viewport with stable columns.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutViewport {
    pub base_width: f64,
    pub columns: Vec<LayoutColumn>,
}

impl<'de> Deserialize<'de> for LayoutViewport {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            base_width: f64,
            columns: Vec<LayoutColumn>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if !wire.base_width.is_finite() || !(0.1..=1.0).contains(&wire.base_width) {
            return Err(serde::de::Error::custom(
                "layout viewport base width must be finite and between 0.1 and 1",
            ));
        }
        if wire.columns.is_empty() {
            return Err(serde::de::Error::custom(
                "layout viewport must contain at least one column",
            ));
        }
        Ok(Self { base_width: wire.base_width, columns: wire.columns })
    }
}

/// Exact recursive node union from the resource catalog.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LayoutNode {
    Leaf(LayoutLeaf),
    Split(LayoutSplit),
    Stack(LayoutStack),
    Viewport(LayoutViewport),
}

impl LayoutNode {
    fn validate(&self) -> crate::Result<()> {
        match self {
            Self::Leaf(_) => Ok(()),
            Self::Split(split) => {
                if !split.ratio.is_finite() || split.ratio <= 0.0 || split.ratio >= 1.0 {
                    return Err(crate::Error::InvalidArgument(
                        "layout split ratio must be finite and between zero and one".to_string(),
                    ));
                }
                split.first.validate()?;
                split.second.validate()
            }
            Self::Stack(stack) => {
                if stack.pane_ids.is_empty() {
                    return Err(crate::Error::InvalidArgument(
                        "layout stack must contain at least one pane".to_string(),
                    ));
                }
                if !stack.pane_ids.contains(&stack.expanded_pane_id) {
                    return Err(crate::Error::InvalidArgument(
                        "layout stack expanded pane must be a stack member".to_string(),
                    ));
                }
                Ok(())
            }
            Self::Viewport(viewport) => {
                if !viewport.base_width.is_finite() || !(0.1..=1.0).contains(&viewport.base_width) {
                    return Err(crate::Error::InvalidArgument(
                        "layout viewport base width must be finite and between 0.1 and 1"
                            .to_string(),
                    ));
                }
                if viewport.columns.is_empty() {
                    return Err(crate::Error::InvalidArgument(
                        "layout viewport must contain at least one column".to_string(),
                    ));
                }
                for column in &viewport.columns {
                    if !column.width.is_finite() || !(0.1..=1.0).contains(&column.width) {
                        return Err(crate::Error::InvalidArgument(
                            "layout column width must be finite and between 0.1 and 1".to_string(),
                        ));
                    }
                    column.root.validate()?;
                }
                Ok(())
            }
        }
    }
}

/// Complete, lossless screen layout document.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutDocument {
    pub version: u32,
    pub screen_id: ScreenId,
    pub active_pane_id: PaneId,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub zoomed_pane_id: Option<PaneId>,
    pub root: LayoutNode,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub extra: BTreeMap<String, Value>,
}

impl LayoutDocument {
    pub fn validate(&self) -> crate::Result<()> {
        self.root.validate()
    }
}

/// Catalog snapshot for one screen.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ScreenSnapshot {
    pub id: ScreenId,
    pub workspace_id: WorkspaceId,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub name: Option<String>,
    pub index: u32,
    pub focused: bool,
    pub layout: LayoutDocument,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Catalog snapshot for one pane.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PaneSnapshot {
    pub id: PaneId,
    pub screen_id: ScreenId,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub name: Option<String>,
    pub focused: bool,
    pub zoomed: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Optional pane found in a requested direction.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PaneNeighborResult {
    pub pane: Option<PaneSnapshot>,
}

/// Kind of resource hosted by a tab.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TabContentKind {
    Terminal,
    Browser,
}

/// Typed content ID hosted by a tab.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TabContentId {
    Terminal(TerminalId),
    Browser(BrowserId),
}

/// Catalog snapshot for one tab.
#[derive(Clone, Debug, PartialEq)]
pub struct TabSnapshot {
    pub id: TabId,
    pub pane_id: PaneId,
    pub name: Option<String>,
    pub index: u32,
    pub focused: bool,
    pub content_kind: TabContentKind,
    pub content_id: TabContentId,
    pub extra: BTreeMap<String, Value>,
}

impl<'de> Deserialize<'de> for TabSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            id: TabId,
            pane_id: PaneId,
            #[serde(deserialize_with = "deserialize_nullable")]
            name: Option<String>,
            index: u32,
            focused: bool,
            content_kind: TabContentKind,
            content_id: String,
            #[serde(default)]
            extra: BTreeMap<String, Value>,
        }

        let wire = Wire::deserialize(deserializer)?;
        let content_id = match wire.content_kind {
            TabContentKind::Terminal => {
                TerminalId::parse(wire.content_id).map(TabContentId::Terminal)
            }
            TabContentKind::Browser => BrowserId::parse(wire.content_id).map(TabContentId::Browser),
        }
        .map_err(serde::de::Error::custom)?;
        Ok(Self {
            id: wire.id,
            pane_id: wire.pane_id,
            name: wire.name,
            index: wire.index,
            focused: wire.focused,
            content_kind: wire.content_kind,
            content_id,
            extra: wire.extra,
        })
    }
}

/// Durable process outcome retained for a terminal.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum TerminalExitOutcome {
    Exit {
        code: i32,
    },
    Signal {
        #[serde(deserialize_with = "deserialize_positive_i32")]
        signal: i32,
        core_dumped: bool,
    },
    Unknown {
        #[serde(deserialize_with = "deserialize_nonempty_string")]
        reason: String,
    },
}

/// Durable terminal exit record.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalExit {
    pub outcome: TerminalExitOutcome,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub exited_at: u64,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
}

/// Current lifecycle state of a terminal.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalLifecycle {
    Launching,
    Running,
    Exited,
}

/// Catalog snapshot for one terminal.
#[derive(Clone, Debug, PartialEq)]
pub struct TerminalSnapshot {
    pub id: TerminalId,
    pub tab_ids: Vec<TabId>,
    pub title: String,
    pub cwd: Option<String>,
    pub cols: u16,
    pub rows: u16,
    pub running: bool,
    pub lifecycle: TerminalLifecycle,
    pub exit: Option<TerminalExit>,
    pub extra: BTreeMap<String, Value>,
}

impl<'de> Deserialize<'de> for TerminalSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            id: TerminalId,
            #[serde(default, deserialize_with = "deserialize_present_nullable")]
            tab_id: Option<Option<TabId>>,
            #[serde(default, deserialize_with = "deserialize_present_nullable")]
            tab_ids: Option<Option<Vec<TabId>>>,
            title: String,
            #[serde(default, deserialize_with = "deserialize_optional_non_null")]
            cwd: Option<String>,
            #[serde(deserialize_with = "deserialize_positive_u16")]
            cols: u16,
            #[serde(deserialize_with = "deserialize_positive_u16")]
            rows: u16,
            running: bool,
            lifecycle: TerminalLifecycle,
            #[serde(default, deserialize_with = "deserialize_optional_non_null")]
            exit: Option<TerminalExit>,
            #[serde(default)]
            extra: BTreeMap<String, Value>,
        }

        let wire = Wire::deserialize(deserializer)?;
        if wire.running != matches!(wire.lifecycle, TerminalLifecycle::Running) {
            return Err(serde::de::Error::custom(
                "terminal running must be true exactly when lifecycle is running",
            ));
        }
        if wire.exit.is_some() != matches!(wire.lifecycle, TerminalLifecycle::Exited) {
            return Err(serde::de::Error::custom(
                "terminal exit must be present exactly when lifecycle is exited",
            ));
        }
        let tab_ids = match (wire.tab_id, wire.tab_ids) {
            (_, Some(None)) => {
                return Err(serde::de::Error::custom("terminal tab_ids must be an array"));
            }
            (legacy, Some(Some(tab_ids))) => {
                if let Some(legacy) = legacy
                    && legacy.as_ref() != tab_ids.first()
                {
                    return Err(serde::de::Error::custom(
                        "terminal tab_id must be the first tab_ids item",
                    ));
                }
                tab_ids
            }
            (Some(legacy), None) => legacy.into_iter().collect(),
            (None, None) => {
                return Err(serde::de::Error::custom(
                    "terminal snapshot requires tab_ids or tab_id",
                ));
            }
        };
        Ok(Self {
            id: wire.id,
            tab_ids,
            title: wire.title,
            cwd: wire.cwd,
            cols: wire.cols,
            rows: wire.rows,
            running: wire.running,
            lifecycle: wire.lifecycle,
            exit: wire.exit,
            extra: wire.extra,
        })
    }
}

/// Source that created a browser.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BrowserSource {
    External,
    Launched,
}

/// Current browser lifecycle state.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum BrowserStatus {
    Starting,
    Live,
    Failed,
}

/// Catalog snapshot for one browser.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct BrowserSnapshot {
    pub id: BrowserId,
    pub tab_id: TabId,
    pub url: String,
    pub title: String,
    pub loading: bool,
    pub source: BrowserSource,
    pub status: BrowserStatus,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub error: Option<String>,
    pub frames_stalled: bool,
    #[serde(deserialize_with = "deserialize_size")]
    pub size: Size,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Transport used by a connected client.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
pub enum ClientTransport {
    #[serde(rename = "unix")]
    Unix,
    #[serde(rename = "websocket")]
    WebSocket,
}

/// Terminal dimensions reported by one connected client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientTerminalSize {
    pub terminal_id: TerminalId,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
    pub participating: bool,
}

impl<'de> Deserialize<'de> for ClientTerminalSize {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            terminal_id: TerminalId,
            #[serde(deserialize_with = "deserialize_nullable_positive_u16")]
            cols: Option<u16>,
            #[serde(deserialize_with = "deserialize_nullable_positive_u16")]
            rows: Option<u16>,
            participating: bool,
        }

        let wire = Wire::deserialize(deserializer)?;
        if wire.cols.is_some() != wire.rows.is_some() {
            return Err(serde::de::Error::custom(
                "client terminal size cols and rows must both be null or both be present",
            ));
        }
        Ok(Self {
            terminal_id: wire.terminal_id,
            cols: wire.cols,
            rows: wire.rows,
            participating: wire.participating,
        })
    }
}

/// Catalog snapshot for one connected client.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ClientSnapshot {
    pub id: ConnectedClientId,
    pub session_id: SessionId,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub name: Option<String>,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub client_kind: Option<String>,
    pub transport: ClientTransport,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub connected_seconds: u64,
    pub attached_terminal_ids: Vec<TerminalId>,
    pub sizes: Vec<ClientTerminalSize>,
    #[serde(rename = "self")]
    pub is_self: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Backward-compatible exact name for ``ClientSnapshot``.
pub type ConnectedClientSnapshot = ClientSnapshot;

/// Catalog snapshot for one notification.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct NotificationSnapshot {
    pub id: NotificationId,
    pub session_id: SessionId,
    pub title: String,
    pub body: String,
    pub level: NotificationLevel,
    #[serde(default, deserialize_with = "deserialize_optional_non_null")]
    pub terminal_id: Option<TerminalId>,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub created_at_ms: u64,
    pub unread: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Source that last reported an agent state.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentSnapshotSource {
    Hook,
    Socket,
    Detected,
}

/// Catalog snapshot for one detected agent.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct AgentSnapshot {
    pub id: AgentId,
    pub session_id: SessionId,
    pub terminal_id: TerminalId,
    pub state: AgentState,
    pub source: AgentSnapshotSource,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub updated_at_ms: u64,
    #[serde(deserialize_with = "deserialize_nullable")]
    pub source_session: Option<String>,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Explicitly revealable pairing secret with redacted formatting.
#[derive(Clone, PartialEq, Eq)]
pub struct PairingCode(String);

impl PairingCode {
    pub fn new(value: impl Into<String>) -> crate::Result<Self> {
        Ok(Self(value.into()))
    }

    /// Explicitly exposes the secret for pairing UI or transport.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for PairingCode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("PairingCode([REDACTED])")
    }
}

impl<'de> Deserialize<'de> for PairingCode {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::new(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

/// Current status of a pairing request.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PairingStatus {
    Pending,
    Accepted,
    Rejected,
}

/// Catalog snapshot for one pairing request.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PairingRequestSnapshot {
    pub id: PairingRequestId,
    pub session_id: SessionId,
    pub peer: String,
    pub code: PairingCode,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub expires_in_seconds: u64,
    pub status: PairingStatus,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Catalog snapshot for one frontend projection.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct FrontendProjectionSnapshot {
    pub id: FrontendProjectionId,
    pub session_id: SessionId,
    pub frontend_id: String,
    pub window_id: String,
    pub generation: String,
    pub projection: Document,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub projection_revision: u64,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Catalog snapshot for one sidebar view.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SidebarViewSnapshot {
    pub id: SidebarViewId,
    pub session_id: SessionId,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub cols: u16,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub rows: u16,
    pub running: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Current durable session revision and generation.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Cursor {
    #[serde(deserialize_with = "deserialize_generation")]
    pub generation: String,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ConfirmationRequiredDetails {
    #[serde(deserialize_with = "deserialize_bounded_nonempty_string")]
    pub confirmation_token: String,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    #[serde(deserialize_with = "deserialize_nonempty_pane_ids")]
    pub closes_panes: Vec<PaneId>,
}

/// Complete catalog session snapshot.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ResourceSnapshot {
    pub machine: MachineSnapshot,
    pub session: SessionSnapshot,
    pub workspaces: Vec<WorkspaceSnapshot>,
    pub screens: Vec<ScreenSnapshot>,
    pub panes: Vec<PaneSnapshot>,
    pub tabs: Vec<TabSnapshot>,
    pub terminals: Vec<TerminalSnapshot>,
    pub browsers: Vec<BrowserSnapshot>,
    pub clients: Vec<ClientSnapshot>,
    pub notifications: Vec<NotificationSnapshot>,
    pub agents: Vec<AgentSnapshot>,
    pub frontend_projections: Vec<FrontendProjectionSnapshot>,
    pub sidebar_views: Vec<SidebarViewSnapshot>,
    pub cursor: Cursor,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Exact typed value carried by a resource upsert.
#[derive(Clone, Debug, PartialEq)]
pub enum ResourceEntitySnapshot {
    Machine(MachineSnapshot),
    Session(SessionSnapshot),
    Workspace(WorkspaceSnapshot),
    Screen(ScreenSnapshot),
    Pane(PaneSnapshot),
    Tab(TabSnapshot),
    Terminal(TerminalSnapshot),
    Browser(BrowserSnapshot),
    Client(ClientSnapshot),
    Notification(NotificationSnapshot),
    Agent(AgentSnapshot),
    PairingRequest(PairingRequestSnapshot),
    FrontendProjection(FrontendProjectionSnapshot),
    SidebarView(SidebarViewSnapshot),
}

/// Exact path returned by create and run operations.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CreatedPath {
    Workspace {
        workspace_id: WorkspaceId,
    },
    Terminal {
        workspace_id: WorkspaceId,
        screen_id: ScreenId,
        pane_id: PaneId,
        tab_id: TabId,
        terminal_id: TerminalId,
    },
    Browser {
        workspace_id: WorkspaceId,
        screen_id: ScreenId,
        pane_id: PaneId,
        tab_id: TabId,
        browser_id: BrowserId,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CreationState {
    Pending,
    Created,
    NotApplied,
    Indeterminate,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CreationRecovery {
    RetrySameIdempotencyKey,
    RetryNewIdempotencyKey,
    Wait,
    None,
    DoNotRetry,
}

/// Reconnect-safe resolution of one creation correlation key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreationResolution {
    pub correlation_key: String,
    pub state: CreationState,
    pub recovery: CreationRecovery,
    pub operation: Option<String>,
    pub idempotency_key: Option<String>,
    pub created_path: Option<CreatedPath>,
    pub generation: Option<String>,
    pub revision: Option<u64>,
}

impl<'de> Deserialize<'de> for CreationResolution {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            #[serde(deserialize_with = "deserialize_bounded_nonempty_string")]
            correlation_key: String,
            state: CreationState,
            recovery: CreationRecovery,
            #[serde(default, deserialize_with = "deserialize_optional_nonempty_string")]
            operation: Option<String>,
            #[serde(default, deserialize_with = "deserialize_optional_bounded_nonempty_string")]
            idempotency_key: Option<String>,
            #[serde(default, deserialize_with = "deserialize_optional_non_null")]
            created_path: Option<CreatedPath>,
            #[serde(default, deserialize_with = "deserialize_optional_generation")]
            generation: Option<String>,
            #[serde(default, deserialize_with = "deserialize_optional_decimal")]
            revision: Option<u64>,
        }

        let wire = Wire::deserialize(deserializer)?;
        let valid_recovery = match wire.state {
            CreationState::Created => wire.recovery == CreationRecovery::None,
            CreationState::Pending => wire.recovery == CreationRecovery::Wait,
            CreationState::NotApplied => matches!(
                wire.recovery,
                CreationRecovery::RetrySameIdempotencyKey
                    | CreationRecovery::RetryNewIdempotencyKey
            ),
            CreationState::Indeterminate => wire.recovery == CreationRecovery::DoNotRetry,
        };
        if !valid_recovery {
            return Err(serde::de::Error::custom(
                "creation state and recovery strategy do not match",
            ));
        }
        if wire.state == CreationState::Created
            && (wire.created_path.is_none() || wire.generation.is_none() || wire.revision.is_none())
        {
            return Err(serde::de::Error::custom(
                "created resolution requires created_path, generation, and revision",
            ));
        }
        Ok(Self {
            correlation_key: wire.correlation_key,
            state: wire.state,
            recovery: wire.recovery,
            operation: wire.operation,
            idempotency_key: wire.idempotency_key,
            created_path: wire.created_path,
            generation: wire.generation,
            revision: wire.revision,
        })
    }
}

impl CreatedPath {
    pub fn workspace_id(&self) -> &WorkspaceId {
        match self {
            Self::Workspace { workspace_id }
            | Self::Terminal { workspace_id, .. }
            | Self::Browser { workspace_id, .. } => workspace_id,
        }
    }

    pub fn screen_id(&self) -> Option<&ScreenId> {
        match self {
            Self::Workspace { .. } => None,
            Self::Terminal { screen_id, .. } | Self::Browser { screen_id, .. } => Some(screen_id),
        }
    }

    pub fn pane_id(&self) -> Option<&PaneId> {
        match self {
            Self::Workspace { .. } => None,
            Self::Terminal { pane_id, .. } | Self::Browser { pane_id, .. } => Some(pane_id),
        }
    }

    pub fn tab_id(&self) -> Option<&TabId> {
        match self {
            Self::Workspace { .. } => None,
            Self::Terminal { tab_id, .. } | Self::Browser { tab_id, .. } => Some(tab_id),
        }
    }

    pub fn terminal_id(&self) -> Option<&TerminalId> {
        match self {
            Self::Terminal { terminal_id, .. } => Some(terminal_id),
            Self::Workspace { .. } | Self::Browser { .. } => None,
        }
    }

    pub fn browser_id(&self) -> Option<&BrowserId> {
        match self {
            Self::Browser { browser_id, .. } => Some(browser_id),
            Self::Workspace { .. } | Self::Terminal { .. } => None,
        }
    }
}

/// A mutation result with canonical flat commit metadata.
#[derive(Clone, Debug, PartialEq)]
pub struct MutationResult<T> {
    pub value: T,
    pub generation: String,
    pub revision: u64,
    pub replayed: bool,
}

impl<T> MutationResult<T> {
    pub fn receipt(&self) -> MutationReceipt {
        MutationResult {
            value: (),
            generation: self.generation.clone(),
            revision: self.revision,
            replayed: self.replayed,
        }
    }

    pub fn cursor(&self) -> Cursor {
        Cursor { generation: self.generation.clone(), revision: self.revision }
    }

    pub fn map<U>(self, map: impl FnOnce(T) -> U) -> MutationResult<U> {
        MutationResult {
            value: map(self.value),
            generation: self.generation,
            revision: self.revision,
            replayed: self.replayed,
        }
    }
}

/// Commit metadata for a mutation whose canonical value is empty.
pub type MutationReceipt = MutationResult<()>;

/// A newly created resource, its complete path, and commit metadata.
#[derive(Clone, Debug, PartialEq)]
pub struct Created<T> {
    pub resource: T,
    pub value: CreatedPath,
    pub generation: String,
    pub revision: u64,
    pub replayed: bool,
}

impl<T> Created<T> {
    pub fn path(&self) -> &CreatedPath {
        &self.value
    }

    pub fn receipt(&self) -> MutationReceipt {
        MutationResult {
            value: (),
            generation: self.generation.clone(),
            revision: self.revision,
            replayed: self.replayed,
        }
    }

    pub fn cursor(&self) -> Cursor {
        Cursor { generation: self.generation.clone(), revision: self.revision }
    }
}

/// Result of a session liveness read.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PingResult {
    pub alive: bool,
    pub cursor: Cursor,
}

/// Result of a session shutdown request.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ShutdownResult {
    pub accepted: bool,
}

/// Result of reloading server configuration.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ReloadConfigResult {
    pub reloaded: bool,
    pub warnings: Vec<String>,
}

/// Updated terminal defaults returned by the session.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalDefaultsSnapshot {
    pub foreground: Option<String>,
    pub background: Option<String>,
    pub cursor: Option<String>,
    pub selection_background: Option<String>,
    pub selection_foreground: Option<String>,
    pub cursor_style: Option<CursorStyle>,
    pub cursor_blink: Option<bool>,
    #[serde(default, deserialize_with = "deserialize_optional_non_null")]
    pub palette: Option<BTreeMap<String, String>>,
}

/// Visible terminal text and cursor metadata.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TerminalScreenResult {
    pub text: String,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub cols: u16,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub rows: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub cursor_visible: bool,
    #[serde(default)]
    pub extra: BTreeMap<String, Value>,
}

/// Serialized terminal emulator state and its dimensions.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalStateResult {
    #[serde(rename = "state_base64", deserialize_with = "deserialize_base64")]
    pub state: Vec<u8>,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub cols: u16,
    #[serde(deserialize_with = "deserialize_positive_u16")]
    pub rows: u16,
}

/// One page of lossless terminal history rows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalHistoryResult {
    pub start: u64,
    pub next: Option<u64>,
    pub rows: Vec<RenderRow>,
}

/// Result of waiting for a terminal pattern.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalWaitResult {
    pub matched: bool,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalPendingLifecycle {
    Launching,
    Running,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TerminalExitedLifecycle {
    Exited,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalWaitExitPending {
    pub terminal_id: TerminalId,
    pub lifecycle: TerminalPendingLifecycle,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalWaitExitExited {
    pub terminal_id: TerminalId,
    pub lifecycle: TerminalExitedLifecycle,
    pub outcome: TerminalExitOutcome,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub exited_at: u64,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
}

/// Bounded wait result. A timeout is the typed pending variant, not an error.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TerminalWaitExitResult {
    Pending(TerminalWaitExitPending),
    Exited(TerminalWaitExitExited),
}

/// Text copied from a selected terminal scope.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct TerminalCopyResult {
    pub mode: CopyMode,
    pub text: String,
}

/// Current terminal process metadata.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ProcessInfoResult {
    pub pid: u32,
    #[serde(default, deserialize_with = "deserialize_optional_non_null")]
    pub executable: Option<String>,
    pub argv: Vec<String>,
    #[serde(default, deserialize_with = "deserialize_optional_non_null")]
    pub cwd: Option<String>,
    pub children: Vec<u32>,
}

/// Result of assigning terminal viewer dimensions.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ViewerResizeResult {
    pub accepted: bool,
    #[serde(deserialize_with = "deserialize_size")]
    pub size: Size,
    pub outcome: ViewAttachmentOutcome,
}

/// Result of assigning browser viewer dimensions.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct BrowserViewerResizeResult {
    pub accepted: bool,
    #[serde(deserialize_with = "deserialize_pixel_size")]
    pub size: PixelSize,
    pub outcome: ViewAttachmentOutcome,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ViewAttachmentOutcome {
    Applied,
    Passive,
    Superseded,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ViewerReleaseResult {
    pub outcome: ViewAttachmentOutcome,
}

/// Result of publishing client cell pixel dimensions.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CellPixelsResult {
    #[serde(deserialize_with = "deserialize_positive_u32")]
    pub width_px: u32,
    #[serde(deserialize_with = "deserialize_positive_u32")]
    pub height_px: u32,
    pub resized_terminals: Vec<TerminalId>,
    pub failures: BTreeMap<String, String>,
}

/// Result of resolving a pairing request.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct PairingResolutionResult {
    pub pairing_request: PairingRequestSnapshot,
}

/// One stream item with sequence and optional recovery cursor.
#[derive(Clone, Debug, PartialEq)]
pub struct StreamItem {
    pub sequence: u64,
    pub cursor: Option<Cursor>,
    pub value: Value,
}

/// Typed stream payload with resumable envelope metadata.
#[derive(Clone, Debug, PartialEq)]
pub struct TypedStreamItem<T> {
    pub sequence: u64,
    pub cursor: Option<Cursor>,
    pub value: T,
}

/// Outcome of one bounded stream poll.
#[derive(Clone, Debug, PartialEq)]
pub enum StreamPoll<T> {
    Item(T),
    End,
    TimedOut,
}

/// End-of-stream metadata.
#[derive(Clone, Debug, PartialEq)]
pub struct StreamEnd {
    pub reason: StreamEndReason,
    pub cursor: Option<Cursor>,
    pub recovery: Option<String>,
    pub error: Option<ProtocolFailure>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProtocolFailure {
    pub code: String,
    pub message: String,
    pub details: Document,
    pub retryable: bool,
}

/// One-use renderer credential. Debug output always redacts the token.
#[derive(Clone, PartialEq, Eq)]
pub struct RendererGrant {
    token: String,
    pub endpoint: String,
    pub terminal_id: TerminalId,
    pub rights: Vec<String>,
    pub ttl_ms: u32,
}

impl RendererGrant {
    pub fn new(
        token: impl Into<String>,
        endpoint: impl Into<String>,
        terminal_id: TerminalId,
        rights: Vec<String>,
        ttl_ms: u32,
    ) -> crate::Result<Self> {
        let token = token.into();
        let endpoint = endpoint.into();
        if token.is_empty() {
            return Err(crate::Error::InvalidArgument(
                "renderer grant token must not be empty".to_string(),
            ));
        }
        if rights.is_empty() {
            return Err(crate::Error::InvalidArgument(
                "renderer grant rights must not be empty".to_string(),
            ));
        }
        if ttl_ms == 0 || ttl_ms > 60_000 {
            return Err(crate::Error::InvalidArgument(
                "renderer grant ttl_ms must be between 1 and 60000".to_string(),
            ));
        }
        Ok(Self { token, endpoint, terminal_id, rights, ttl_ms })
    }

    /// Explicitly exposes the credential for transport to the renderer.
    pub fn expose_token(&self) -> &str {
        &self.token
    }
}

impl std::fmt::Debug for RendererGrant {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RendererGrant")
            .field("token", &"[REDACTED]")
            .field("endpoint", &self.endpoint)
            .field("terminal_id", &self.terminal_id)
            .field("rights", &self.rights)
            .field("ttl_ms", &self.ttl_ms)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamEndReason {
    Completed,
    Canceled,
    Closed,
    Gap,
    Error,
}

impl StreamEndReason {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "completed" => Self::Completed,
            "canceled" => Self::Canceled,
            "closed" => Self::Closed,
            "gap" => Self::Gap,
            "error" => Self::Error,
            _ => return None,
        })
    }
}

fn deserialize_optional_non_null<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

fn deserialize_nullable<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer)
}

fn deserialize_present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

fn deserialize_generation<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value.is_empty() || value.len() > 128 {
        return Err(serde::de::Error::custom("generation must contain 1 to 128 UTF-8 bytes"));
    }
    Ok(value)
}

fn deserialize_nonempty_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value.is_empty() {
        return Err(serde::de::Error::custom("string must not be empty"));
    }
    Ok(value)
}

fn deserialize_bounded_nonempty_string<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = deserialize_nonempty_string(deserializer)?;
    if value.len() > 128 {
        return Err(serde::de::Error::custom("string must contain at most 128 UTF-8 bytes"));
    }
    Ok(value)
}

fn deserialize_optional_nonempty_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    deserialize_nonempty_string(deserializer).map(Some)
}

fn deserialize_optional_bounded_nonempty_string<'de, D>(
    deserializer: D,
) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    deserialize_bounded_nonempty_string(deserializer).map(Some)
}

fn deserialize_optional_generation<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    deserialize_generation(deserializer).map(Some)
}

fn deserialize_decimal<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value.is_empty()
        || value.starts_with('+')
        || (value.starts_with('0') && value.len() > 1)
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(serde::de::Error::custom("decimal must be a canonical uint64 string"));
    }
    value.parse().map_err(serde::de::Error::custom)
}

fn deserialize_optional_decimal<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    deserialize_decimal(deserializer).map(Some)
}

fn deserialize_positive_i32<'de, D>(deserializer: D) -> Result<i32, D::Error>
where
    D: Deserializer<'de>,
{
    let value = i32::deserialize(deserializer)?;
    if value < 1 {
        return Err(serde::de::Error::custom("signal must be greater than zero"));
    }
    Ok(value)
}

fn deserialize_positive_u16<'de, D>(deserializer: D) -> Result<u16, D::Error>
where
    D: Deserializer<'de>,
{
    let value = u16::deserialize(deserializer)?;
    if value == 0 {
        return Err(serde::de::Error::custom("dimension must be greater than zero"));
    }
    Ok(value)
}

fn deserialize_nonempty_pane_ids<'de, D>(deserializer: D) -> Result<Vec<PaneId>, D::Error>
where
    D: Deserializer<'de>,
{
    let values = Vec::<PaneId>::deserialize(deserializer)?;
    if values.is_empty() {
        return Err(serde::de::Error::custom("closes_panes must not be empty"));
    }
    Ok(values)
}

fn deserialize_nullable_positive_u16<'de, D>(deserializer: D) -> Result<Option<u16>, D::Error>
where
    D: Deserializer<'de>,
{
    Option::<u16>::deserialize(deserializer)?
        .map(|value| {
            if value == 0 {
                Err(serde::de::Error::custom("dimension must be greater than zero"))
            } else {
                Ok(value)
            }
        })
        .transpose()
}

fn deserialize_positive_u32<'de, D>(deserializer: D) -> Result<u32, D::Error>
where
    D: Deserializer<'de>,
{
    let value = u32::deserialize(deserializer)?;
    if value == 0 {
        return Err(serde::de::Error::custom("value must be greater than zero"));
    }
    Ok(value)
}

fn deserialize_size<'de, D>(deserializer: D) -> Result<Size, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wire {
        #[serde(deserialize_with = "deserialize_positive_u16")]
        cols: u16,
        #[serde(deserialize_with = "deserialize_positive_u16")]
        rows: u16,
    }

    let wire = Wire::deserialize(deserializer)?;
    Ok(Size { cols: wire.cols, rows: wire.rows })
}

fn deserialize_pixel_size<'de, D>(deserializer: D) -> Result<PixelSize, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wire {
        #[serde(deserialize_with = "deserialize_positive_u32")]
        width_px: u32,
        #[serde(deserialize_with = "deserialize_positive_u32")]
        height_px: u32,
    }

    let wire = Wire::deserialize(deserializer)?;
    Ok(PixelSize { width_px: wire.width_px, height_px: wire.height_px })
}

fn deserialize_base64<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    base64::engine::general_purpose::STANDARD.decode(value).map_err(serde::de::Error::custom)
}

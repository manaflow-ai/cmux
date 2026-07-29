use super::id::*;
use serde_json::Value;
use std::collections::BTreeMap;

/// Forward-compatible JSON document used for layouts and extension payloads.
#[derive(Clone, Debug, PartialEq)]
pub struct Document(pub(crate) Value);

impl Document {
    pub fn deserialize<T: serde::de::DeserializeOwned>(&self) -> crate::Result<T> {
        serde_json::from_value(self.0.clone())
            .map_err(|error| crate::Error::Decode(error.to_string()))
    }

    pub fn from_serializable<T: serde::Serialize>(value: &T) -> crate::Result<Self> {
        serde_json::to_value(value)
            .map(Self)
            .map_err(|error| crate::Error::Decode(error.to_string()))
    }
}

/// Typed ancestry retained by every resource snapshot.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ParentIds {
    pub machine: Option<MachineId>,
    pub session: Option<SessionId>,
    pub workspace: Option<WorkspaceId>,
    pub screen: Option<ScreenId>,
    pub pane: Option<PaneId>,
    pub tab: Option<TabId>,
}

/// Forward-compatible snapshot returned by an explicit handle refresh.
#[derive(Clone, Debug, PartialEq)]
pub struct ResourceSnapshot<I> {
    pub id: I,
    pub name: Option<String>,
    pub parents: ParentIds,
    pub revision: Option<u64>,
    /// Fields unknown to this SDK version, preserved without interpretation.
    pub extra: BTreeMap<String, Value>,
}

pub type MachineSnapshot = ResourceSnapshot<MachineId>;
pub type SessionSnapshot = ResourceSnapshot<SessionId>;
pub type WorkspaceSnapshot = ResourceSnapshot<WorkspaceId>;
pub type ScreenSnapshot = ResourceSnapshot<ScreenId>;
pub type PaneSnapshot = ResourceSnapshot<PaneId>;
pub type TabSnapshot = ResourceSnapshot<TabId>;
pub type TerminalSnapshot = ResourceSnapshot<TerminalId>;
pub type BrowserSnapshot = ResourceSnapshot<BrowserId>;
pub type ConnectedClientSnapshot = ResourceSnapshot<ConnectedClientId>;
pub type NotificationSnapshot = ResourceSnapshot<NotificationId>;
pub type AgentSnapshot = ResourceSnapshot<AgentId>;
pub type PairingRequestSnapshot = ResourceSnapshot<PairingRequestId>;
pub type FrontendProjectionSnapshot = ResourceSnapshot<FrontendProjectionId>;
pub type SidebarViewSnapshot = ResourceSnapshot<SidebarViewId>;
pub type ProviderScopeSnapshot = ResourceSnapshot<ProviderScopeId>;
pub type ProviderActionSnapshot = ResourceSnapshot<ProviderActionId>;
pub type ProviderNoticeSnapshot = ResourceSnapshot<ProviderNoticeId>;

/// Exact path returned by create and run operations.
#[derive(Clone, Debug, PartialEq, Eq)]
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

/// Current durable session revision and generation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Cursor {
    pub generation: String,
    pub revision: u64,
}

/// A raw session snapshot retained for forward compatibility.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub cursor: Cursor,
    pub document: Document,
}

/// One stream item with sequence and optional recovery cursor.
#[derive(Clone, Debug, PartialEq)]
pub struct StreamItem {
    pub sequence: u64,
    pub cursor: Option<Cursor>,
    pub value: Value,
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
        if endpoint.is_empty() {
            return Err(crate::Error::InvalidArgument(
                "renderer grant endpoint must not be empty".to_string(),
            ));
        }
        if rights.is_empty() || rights.iter().any(String::is_empty) {
            return Err(crate::Error::InvalidArgument(
                "renderer grant rights must contain non-empty values".to_string(),
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

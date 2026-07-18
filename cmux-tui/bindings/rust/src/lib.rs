use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Duration;

pub const CANONICAL_TOPOLOGY_SNAPSHOT_CAPABILITY: &str = "canonical-topology-snapshot-v1";
pub const STABLE_ENTITY_UUID_CAPABILITY: &str = "stable-entity-uuid-v1";
pub const TOPOLOGY_RESUME_CAPABILITY: &str = "topology-resume-v1";
pub const TOPOLOGY_V8_CAPABILITIES: [&str; 3] = [
    CANONICAL_TOPOLOGY_SNAPSHOT_CAPABILITY,
    STABLE_ENTITY_UUID_CAPABILITY,
    TOPOLOGY_RESUME_CAPABILITY,
];

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Uuid(String);

impl Uuid {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Uuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for Uuid {
    type Err = String;

    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        let bytes = value.as_bytes();
        let valid = bytes.len() == 36
            && bytes.iter().enumerate().all(|(index, byte)| match index {
                8 | 13 | 18 | 23 => *byte == b'-',
                _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(byte),
            });
        valid
            .then(|| Self(value.to_string()))
            .ok_or_else(|| format!("invalid lowercase UUID {value:?}"))
    }
}

impl Serialize for Uuid {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for Uuid {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        value.parse().map_err(serde::de::Error::custom)
    }
}

pub type Result<T> = std::result::Result<T, CmuxError>;

#[derive(Debug)]
pub enum CmuxError {
    Command { message: String, id: Option<Value> },
    Decode(String),
    Connection(String),
    Timeout(String),
    ProtocolVersion(String),
}

impl fmt::Display for CmuxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command { message, .. } => write!(f, "{message}"),
            Self::Decode(message)
            | Self::Connection(message)
            | Self::Timeout(message)
            | Self::ProtocolVersion(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for CmuxError {}

#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub socket_path: PathBuf,
    pub timeout: Duration,
    pub allow_protocol_v6_attach: bool,
}

impl ClientConfig {
    pub fn from_socket_path(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
            timeout: Duration::from_secs(10),
            allow_protocol_v6_attach: true,
        }
    }

    pub fn from_env_or_default_session(session: &str) -> Self {
        let socket_path = env_socket_path().unwrap_or_else(|| default_socket_path(session));
        Self::from_socket_path(socket_path)
    }
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self::from_env_or_default_session("main")
    }
}

pub fn env_socket_path() -> Option<PathBuf> {
    std::env::var_os("CMUX_TUI_SOCKET")
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var_os("CMUX_MUX_SOCKET").filter(|value| !value.is_empty()))
        .map(PathBuf::from)
}

pub fn default_socket_path(session: &str) -> PathBuf {
    let runtime_base = default_runtime_base();
    default_socket_path_from(
        &runtime_base,
        &current_uid_component(),
        session,
        if cfg!(target_os = "macos") { Some(103) } else { None },
    )
}

fn default_socket_path_from(
    runtime_base: &Path,
    uid: &str,
    session: &str,
    max_bytes: Option<usize>,
) -> PathBuf {
    let candidate = runtime_base.join(format!("cmux-tui-{uid}")).join(format!("{session}.sock"));
    if max_bytes.is_some_and(|limit| socket_path_bytes(&candidate) > limit) {
        PathBuf::from("/tmp").join(format!("cmux-tui-{uid}")).join(format!("{session}.sock"))
    } else {
        candidate
    }
}

fn socket_path_bytes(path: &Path) -> usize {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        path.as_os_str().as_bytes().len()
    }
    #[cfg(not(unix))]
    {
        path.as_os_str().to_string_lossy().len()
    }
}

#[cfg(not(windows))]
fn default_runtime_base() -> PathBuf {
    nonempty_env_path("XDG_RUNTIME_DIR")
        .or_else(|| nonempty_env_path("TMPDIR"))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

#[cfg(windows)]
fn default_runtime_base() -> PathBuf {
    nonempty_env_path("TEMP")
        .or_else(|| nonempty_env_path("TMP"))
        .unwrap_or_else(std::env::temp_dir)
}

fn nonempty_env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    (!value.is_empty()).then(|| PathBuf::from(value))
}

#[cfg(unix)]
fn current_uid_component() -> String {
    unsafe { libc::getuid() }.to_string()
}

#[cfg(not(unix))]
fn current_uid_component() -> String {
    std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string())
}

#[derive(Debug, Clone, Deserialize)]
pub struct IdentifyResult {
    pub app: String,
    pub version: String,
    pub protocol: u32,
    #[serde(default)]
    pub protocol_min: Option<u32>,
    #[serde(default)]
    pub protocol_max: Option<u32>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub session: String,
    #[serde(default)]
    pub session_id: Option<Uuid>,
    #[serde(default)]
    pub daemon_instance_id: Option<Uuid>,
    #[serde(default)]
    pub topology_revision: Option<u64>,
    #[serde(default)]
    pub canonical_topology_revision: Option<u64>,
    pub pid: u32,
}

impl IdentifyResult {
    pub fn supports_topology_v8(&self) -> bool {
        self.protocol >= 8
            && TOPOLOGY_V8_CAPABILITIES
                .iter()
                .all(|required| self.capabilities.iter().any(|actual| actual == required))
    }

    pub fn topology_cursor(&self) -> Option<TopologyCursor> {
        Some(TopologyCursor {
            daemon_instance_id: self.daemon_instance_id.clone()?,
            session_id: self.session_id.clone()?,
            revision: self.canonical_topology_revision?,
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct PingResult {
    pub ok: bool,
    pub version: String,
    pub protocol: u32,
    #[serde(default)]
    pub protocol_min: Option<u32>,
    #[serde(default)]
    pub protocol_max: Option<u32>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub session_id: Option<Uuid>,
    #[serde(default)]
    pub daemon_instance_id: Option<Uuid>,
    #[serde(default)]
    pub topology_revision: Option<u64>,
    #[serde(default)]
    pub canonical_topology_revision: Option<u64>,
    #[serde(default)]
    pub pid: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologyAuthority {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologyCursor {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
    pub revision: u64,
}

impl TopologyCursor {
    pub fn authority(&self) -> TopologyAuthority {
        TopologyAuthority {
            daemon_instance_id: self.daemon_instance_id.clone(),
            session_id: self.session_id.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalTopology {
    pub workspaces: Vec<CanonicalWorkspace>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalWorkspace {
    pub id: u64,
    pub uuid: Uuid,
    pub name: String,
    pub screens: Vec<CanonicalScreen>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalScreen {
    pub id: u64,
    pub uuid: Uuid,
    pub name: Option<String>,
    pub layout: CanonicalLayout,
    pub panes: Vec<CanonicalPane>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum CanonicalLayout {
    #[serde(rename = "leaf")]
    Leaf { pane: u64, pane_uuid: Uuid },
    #[serde(rename = "split")]
    Split { dir: String, ratio: f32, a: Box<CanonicalLayout>, b: Box<CanonicalLayout> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CanonicalPane {
    pub id: u64,
    pub uuid: Uuid,
    pub name: Option<String>,
    pub tabs: Vec<CanonicalTab>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalTab {
    pub id: u64,
    pub uuid: Uuid,
    pub kind: CanonicalTabKind,
    pub name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CanonicalTabKind {
    Pty,
    Browser,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TopologySnapshot {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
    pub revision: u64,
    pub topology: CanonicalTopology,
}

impl TopologySnapshot {
    pub fn cursor(&self) -> TopologyCursor {
        TopologyCursor {
            daemon_instance_id: self.daemon_instance_id.clone(),
            session_id: self.session_id.clone(),
            revision: self.revision,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct TopologyTargets {
    #[serde(default)]
    pub workspaces: Vec<Uuid>,
    #[serde(default)]
    pub screens: Vec<Uuid>,
    #[serde(default)]
    pub panes: Vec<Uuid>,
    #[serde(default)]
    pub surfaces: Vec<Uuid>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TopologyOperation {
    WorkspaceCreated,
    ScreenCreated,
    PaneSplit,
    SurfaceAttached,
    SurfaceClosed,
    PaneClosed,
    ScreenClosed,
    WorkspaceClosed,
    WorkspaceRenamed,
    ScreenRenamed,
    PaneRenamed,
    SurfaceRenamed,
    SplitRatioChanged,
    PanesSwapped,
    LayoutApplied,
    TabMoved,
    WorkspaceMoved,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TopologyDelta {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
    pub base_revision: u64,
    pub revision: u64,
    pub operation: TopologyOperation,
    pub targets: TopologyTargets,
    pub replacement: CanonicalTopology,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TopologyResnapshotReason {
    StaleDaemon,
    StaleSession,
    RevisionAhead,
    HistoryGap,
    ReplayTooLarge,
    SlowConsumer,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologyResnapshotRequired {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
    #[serde(default)]
    pub current_revision: Option<u64>,
    pub reason: TopologyResnapshotReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologySubscribed {
    pub daemon_instance_id: Uuid,
    pub session_id: Uuid,
    pub from_revision: u64,
    pub current_revision: u64,
    pub replayed: usize,
}

pub enum TopologySubscribeOutcome {
    Subscribed { info: TopologySubscribed, stream: TopologyStream },
    ResnapshotRequired(TopologyResnapshotRequired),
}

#[derive(Debug, Clone, PartialEq)]
pub enum TopologyStreamEvent {
    Delta(TopologyDelta),
    ResnapshotRequired(TopologyResnapshotRequired),
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResult {
    pub surface: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReadScreenResult {
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ProcessInfoResult {
    pub pid: Option<u32>,
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    pub tty: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct EnsureTerminalEnvironment {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct EnsureTerminalOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub argv: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub env: Vec<EnsureTerminalEnvironment>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initial_input: Option<String>,
    pub wait_after_command: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct EnsureTerminalResult {
    pub created: bool,
    pub workspace: u64,
    pub workspace_uuid: Uuid,
    pub screen: u64,
    pub screen_uuid: Uuid,
    pub pane: u64,
    pub pane_uuid: Uuid,
    pub surface: u64,
    pub surface_uuid: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ReparentTerminalResult {
    pub moved: bool,
    pub workspace: u64,
    pub workspace_uuid: Uuid,
    pub screen: u64,
    pub screen_uuid: Uuid,
    pub pane: u64,
    pub pane_uuid: Uuid,
    pub surface: u64,
    pub surface_uuid: Uuid,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VtStateResult {
    pub cols: u16,
    pub rows: u16,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tree {
    pub workspaces: Vec<Workspace>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Workspace {
    pub id: u64,
    pub name: String,
    pub active: bool,
    pub screens: Vec<Screen>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Screen {
    pub id: u64,
    pub name: Option<String>,
    pub active: bool,
    pub active_pane: u64,
    pub layout: Layout,
    pub panes: Vec<Pane>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type")]
pub enum Layout {
    #[serde(rename = "leaf")]
    Leaf { pane: u64 },
    #[serde(rename = "split")]
    Split { dir: String, ratio: f32, a: Box<Layout>, b: Box<Layout> },
}

#[derive(Debug, Clone, Deserialize)]
pub struct Pane {
    pub id: u64,
    pub name: Option<String>,
    #[serde(default)]
    pub active_tab: usize,
    #[serde(default)]
    pub tabs: Vec<Tab>,
    #[serde(default)]
    pub dead: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tab {
    pub surface: u64,
    pub kind: String,
    pub browser_source: Option<String>,
    pub name: Option<String>,
    pub title: String,
    pub size: Option<Size>,
    pub dead: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ResizeSurfaceResult {
    #[serde(default = "default_true")]
    pub accepted: bool,
    #[serde(default)]
    pub reservation_id: Option<u64>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceEvent {
    pub surface: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TitleChangedEvent {
    pub surface: u64,
    pub title: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResizedEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub reservation_id: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResizeFailedEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    pub error: String,
    pub retry_after_ms: Option<u64>,
    #[serde(default)]
    pub reservation_id: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LayoutChangedEvent {
    pub screen: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VtStateEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OutputEvent {
    pub surface: u64,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ResizedEvent {
    pub surface: u64,
    pub cols: u16,
    pub rows: u16,
    #[serde(alias = "data")]
    pub replay: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct OverflowEvent {
    pub error: String,
    pub scope: Option<String>,
    pub surface: Option<u64>,
}

#[non_exhaustive]
#[derive(Debug, Clone)]
pub enum Event {
    TreeChanged,
    LayoutChanged(LayoutChangedEvent),
    SurfaceOutput(SurfaceEvent),
    SurfaceResized(SurfaceResizedEvent),
    SurfaceResizeFailed(SurfaceResizeFailedEvent),
    SurfaceExited(SurfaceEvent),
    TitleChanged(TitleChangedEvent),
    Bell(SurfaceEvent),
    Empty,
    VtState(VtStateEvent),
    Output(OutputEvent),
    Resized(ResizedEvent),
    Detached(SurfaceEvent),
    Overflow(OverflowEvent),
    TopologyDelta(TopologyDelta),
    TopologyResnapshotRequired(TopologyResnapshotRequired),
    Unknown(Value),
}

pub struct CmuxClient {
    config: ClientConfig,
    conn: JsonLineConnection,
    next_id: u64,
    protocol: Option<u32>,
    identity: Option<IdentifyResult>,
}

impl CmuxClient {
    pub fn connect(config: ClientConfig) -> Result<Self> {
        let conn = JsonLineConnection::connect(&config.socket_path, config.timeout)?;
        Ok(Self { config, conn, next_id: 1, protocol: None, identity: None })
    }

    pub fn send_raw(&mut self, mut request: Map<String, Value>) -> Result<Value> {
        if !request.contains_key("id") {
            let id = self.next_id();
            request.insert("id".to_string(), Value::from(id));
        }
        let request_id = request.get("id").cloned();
        self.conn.send(&Value::Object(request))?;
        loop {
            let response = self.conn.recv()?;
            if response.get("event").is_some() {
                continue;
            }
            if response.get("id") != request_id.as_ref() && response.get("id").is_some() {
                continue;
            }
            return Ok(response);
        }
    }

    pub fn request<T: for<'de> Deserialize<'de>>(
        &mut self,
        cmd: &str,
        params: Map<String, Value>,
    ) -> Result<T> {
        let mut request = params;
        let id = self.next_id();
        request.insert("id".to_string(), Value::from(id));
        request.insert("cmd".to_string(), Value::from(cmd));
        let response = self.send_raw(request)?;
        if response.get("ok") == Some(&Value::Bool(true)) {
            let data = response.get("data").cloned().unwrap_or(Value::Object(Map::new()));
            serde_json::from_value(data).map_err(|err| CmuxError::Decode(err.to_string()))
        } else {
            Err(CmuxError::Command {
                message: response
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error")
                    .to_string(),
                id: response.get("id").cloned(),
            })
        }
    }

    pub fn identify(&mut self) -> Result<IdentifyResult> {
        let result: IdentifyResult = self.request("identify", Map::new())?;
        self.protocol = Some(result.protocol);
        self.identity = Some(result.clone());
        Ok(result)
    }

    pub fn ping(&mut self) -> Result<PingResult> {
        self.request("ping", Map::new())
    }

    pub fn topology_snapshot(&mut self) -> Result<TopologySnapshot> {
        self.require_topology_v8()?;
        self.request("topology-snapshot", Map::new())
    }

    pub fn subscribe_topology(
        &mut self,
        cursor: TopologyCursor,
    ) -> Result<TopologySubscribeOutcome> {
        self.require_topology_v8()?;
        let mut params = Map::new();
        params.insert(
            "daemon_instance_id".to_string(),
            Value::String(cursor.daemon_instance_id.to_string()),
        );
        params.insert("session_id".to_string(), Value::String(cursor.session_id.to_string()));
        params.insert("revision".to_string(), Value::from(cursor.revision));
        let id = self.next_id();
        params.insert("id".to_string(), Value::from(id));
        params.insert("cmd".to_string(), Value::from("subscribe-topology"));
        let (data, mut stream) = CmuxStream::open_with_response(
            &self.config.socket_path,
            self.config.timeout,
            &Value::Object(params),
        )?;
        match data.get("status").and_then(Value::as_str) {
            Some("subscribed") => {
                let info = serde_json::from_value::<TopologySubscribed>(data)
                    .map_err(|error| CmuxError::Decode(error.to_string()))?;
                if info.daemon_instance_id != cursor.daemon_instance_id
                    || info.session_id != cursor.session_id
                    || info.from_revision != cursor.revision
                {
                    stream.close();
                    return Ok(TopologySubscribeOutcome::ResnapshotRequired(
                        topology_fence_failure(
                            cursor,
                            info.daemon_instance_id,
                            info.session_id,
                            info.current_revision,
                        ),
                    ));
                }
                Ok(TopologySubscribeOutcome::Subscribed {
                    info,
                    stream: TopologyStream { stream, cursor },
                })
            }
            Some("resnapshot-required") => {
                stream.close();
                let required = serde_json::from_value::<TopologyResnapshotRequired>(data)
                    .map_err(|error| CmuxError::Decode(error.to_string()))?;
                Ok(TopologySubscribeOutcome::ResnapshotRequired(required))
            }
            status => {
                stream.close();
                Err(CmuxError::Decode(format!(
                    "invalid subscribe-topology status {}",
                    status.unwrap_or("<missing>")
                )))
            }
        }
    }

    fn require_topology_v8(&mut self) -> Result<IdentifyResult> {
        let identity = match self.identity.clone() {
            Some(identity) => identity,
            None => self.identify()?,
        };
        if !identity.supports_topology_v8() {
            let missing = TOPOLOGY_V8_CAPABILITIES
                .iter()
                .filter(|required| !identity.capabilities.iter().any(|actual| actual == **required))
                .copied()
                .collect::<Vec<_>>();
            return Err(CmuxError::ProtocolVersion(format!(
                "canonical topology requires protocol 8 and capabilities {}; server protocol={} missing={}",
                TOPOLOGY_V8_CAPABILITIES.join(","),
                identity.protocol,
                missing.join(",")
            )));
        }
        if identity.topology_cursor().is_none() {
            return Err(CmuxError::ProtocolVersion(
                "canonical topology identify response omitted its authority cursor".to_string(),
            ));
        }
        Ok(identity)
    }

    pub fn list_workspaces(&mut self) -> Result<Tree> {
        self.request("list-workspaces", Map::new())
    }

    pub fn send(&mut self, surface: u64, text: Option<&str>, bytes: Option<&str>) -> Result<()> {
        let mut params = Map::new();
        params.insert("surface".to_string(), Value::from(surface));
        insert_opt(&mut params, "text", text);
        insert_opt(&mut params, "bytes", bytes);
        self.request::<Empty>("send", params).map(|_| ())
    }

    pub fn read_screen(&mut self, surface: u64) -> Result<ReadScreenResult> {
        self.request("read-screen", surface_params(surface))
    }

    pub fn process_info(&mut self, surface: u64) -> Result<ProcessInfoResult> {
        self.request("process-info", surface_params(surface))
    }

    pub fn ensure_terminal(
        &mut self,
        workspace_uuid: &Uuid,
        surface_uuid: &Uuid,
        cols: u16,
        rows: u16,
        options: &EnsureTerminalOptions,
    ) -> Result<EnsureTerminalResult> {
        if options.argv.is_some() && options.command.is_some() {
            return Err(CmuxError::Decode(
                "ensure-terminal argv and command are mutually exclusive".to_string(),
            ));
        }
        let mut params = serde_json::to_value(options)
            .map_err(|error| CmuxError::Decode(error.to_string()))?
            .as_object()
            .cloned()
            .ok_or_else(|| {
                CmuxError::Decode("ensure-terminal options must encode as an object".to_string())
            })?;
        params.insert("workspace_uuid".to_string(), Value::from(workspace_uuid.as_str()));
        params.insert("surface_uuid".to_string(), Value::from(surface_uuid.as_str()));
        params.insert("cols".to_string(), Value::from(cols));
        params.insert("rows".to_string(), Value::from(rows));
        self.request("ensure-terminal", params)
    }

    pub fn reparent_terminal(
        &mut self,
        surface_uuid: &Uuid,
        workspace_uuid: &Uuid,
    ) -> Result<ReparentTerminalResult> {
        let mut params = Map::new();
        params.insert("surface_uuid".to_string(), Value::from(surface_uuid.as_str()));
        params.insert("workspace_uuid".to_string(), Value::from(workspace_uuid.as_str()));
        self.request("reparent-terminal", params)
    }

    pub fn vt_state(&mut self, surface: u64) -> Result<VtStateResult> {
        self.request("vt-state", surface_params(surface))
    }

    pub fn new_tab(
        &mut self,
        pane: Option<u64>,
        cwd: Option<&str>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "cwd", cwd);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-tab", params)
    }

    pub fn new_browser_tab(
        &mut self,
        url: &str,
        pane: Option<u64>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        params.insert("url".to_string(), Value::from(url));
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-browser-tab", params)
    }

    pub fn new_workspace(
        &mut self,
        name: Option<&str>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "name", name);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-workspace", params)
    }

    pub fn new_screen(
        &mut self,
        workspace: Option<u64>,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", workspace);
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-screen", params)
    }

    pub fn split(
        &mut self,
        pane: u64,
        dir: &str,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("dir".to_string(), Value::from(dir));
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("split", params)
    }

    pub fn set_ratio(&mut self, pane: u64, dir: &str, ratio: f32) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("dir".to_string(), Value::from(dir));
        params.insert("ratio".to_string(), Value::from(ratio));
        self.request::<Empty>("set-ratio", params).map(|_| ())
    }

    pub fn set_default_colors(&mut self, fg: Option<&str>, bg: Option<&str>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "fg", fg);
        insert_opt(&mut params, "bg", bg);
        self.request::<Empty>("set-default-colors", params).map(|_| ())
    }

    pub fn close_surface(&mut self, surface: u64) -> Result<()> {
        self.request::<Empty>("close-surface", surface_params(surface)).map(|_| ())
    }

    pub fn close_pane(&mut self, pane: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        self.request::<Empty>("close-pane", params).map(|_| ())
    }

    pub fn close_screen(&mut self, screen: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("screen".to_string(), Value::from(screen));
        self.request::<Empty>("close-screen", params).map(|_| ())
    }

    pub fn close_workspace(&mut self, workspace: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        self.request::<Empty>("close-workspace", params).map(|_| ())
    }

    pub fn rename_pane(&mut self, pane: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-pane", params).map(|_| ())
    }

    pub fn rename_surface(&mut self, surface: u64, name: &str) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-surface", params).map(|_| ())
    }

    pub fn rename_screen(&mut self, screen: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("screen".to_string(), Value::from(screen));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-screen", params).map(|_| ())
    }

    pub fn rename_workspace(&mut self, workspace: u64, name: &str) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        params.insert("name".to_string(), Value::from(name));
        self.request::<Empty>("rename-workspace", params).map(|_| ())
    }

    pub fn resize_surface(
        &mut self,
        surface: u64,
        cols: u16,
        rows: u16,
    ) -> Result<ResizeSurfaceResult> {
        let mut params = surface_params(surface);
        params.insert("cols".to_string(), Value::from(cols));
        params.insert("rows".to_string(), Value::from(rows));
        self.request("resize-surface", params)
    }

    pub fn release_surface_size(&mut self, surface: u64) -> Result<()> {
        self.request::<Empty>("release-surface-size", surface_params(surface)).map(|_| ())
    }

    pub fn focus_pane(&mut self, pane: u64) -> Result<()> {
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        self.request::<Empty>("focus-pane", params).map(|_| ())
    }

    pub fn select_tab(
        &mut self,
        pane: Option<u64>,
        index: Option<usize>,
        delta: Option<isize>,
    ) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "pane", pane);
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-tab", params).map(|_| ())
    }

    pub fn select_screen(&mut self, index: Option<usize>, delta: Option<isize>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-screen", params).map(|_| ())
    }

    pub fn select_workspace(&mut self, index: Option<usize>, delta: Option<isize>) -> Result<()> {
        let mut params = Map::new();
        insert_opt(&mut params, "index", index);
        insert_opt(&mut params, "delta", delta);
        self.request::<Empty>("select-workspace", params).map(|_| ())
    }

    pub fn move_tab(&mut self, surface: u64, pane: u64, index: usize) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("pane".to_string(), Value::from(pane));
        params.insert("index".to_string(), Value::from(index));
        self.request::<Empty>("move-tab", params).map(|_| ())
    }

    pub fn move_workspace(&mut self, workspace: u64, index: usize) -> Result<()> {
        let mut params = Map::new();
        params.insert("workspace".to_string(), Value::from(workspace));
        params.insert("index".to_string(), Value::from(index));
        self.request::<Empty>("move-workspace", params).map(|_| ())
    }

    pub fn scroll_surface(&mut self, surface: u64, delta: isize) -> Result<()> {
        let mut params = surface_params(surface);
        params.insert("delta".to_string(), Value::from(delta));
        self.request::<Empty>("scroll-surface", params).map(|_| ())
    }

    pub fn subscribe(&mut self) -> Result<CmuxStream> {
        self.open_stream("subscribe", Map::new())
    }

    pub fn attach_surface(&mut self, surface: u64) -> Result<CmuxStream> {
        let protocol = match self.protocol {
            Some(protocol) => protocol,
            None => self.identify()?.protocol,
        };
        if protocol > 8 || (protocol > 5 && !self.config.allow_protocol_v6_attach) {
            return Err(CmuxError::ProtocolVersion(format!(
                "unsupported attach protocol {protocol}"
            )));
        }
        self.open_stream("attach-surface", surface_params(surface))
    }

    fn open_stream(&mut self, cmd: &str, mut params: Map<String, Value>) -> Result<CmuxStream> {
        let id = self.next_id();
        params.insert("id".to_string(), Value::from(id));
        params.insert("cmd".to_string(), Value::from(cmd));
        CmuxStream::open(&self.config.socket_path, self.config.timeout, &Value::Object(params))
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}

pub struct CmuxStream {
    conn: JsonLineConnection,
    buffered: Vec<Event>,
    finished: bool,
}

impl CmuxStream {
    fn open(socket_path: &PathBuf, timeout: Duration, request: &Value) -> Result<Self> {
        Self::open_with_response(socket_path, timeout, request).map(|(_, stream)| stream)
    }

    fn open_with_response(
        socket_path: &PathBuf,
        timeout: Duration,
        request: &Value,
    ) -> Result<(Value, Self)> {
        let mut conn = JsonLineConnection::connect(socket_path, timeout)?;
        let request_id = request.get("id").cloned();
        conn.send(request)?;
        let mut buffered = Vec::new();
        loop {
            let response = conn.recv()?;
            if response.get("event").is_some() {
                buffered.push(parse_event(response));
                continue;
            }
            if response.get("id") != request_id.as_ref() {
                continue;
            }
            if response.get("ok") == Some(&Value::Bool(true)) {
                let data = response.get("data").cloned().unwrap_or(Value::Object(Map::new()));
                return Ok((data, Self { conn, buffered, finished: false }));
            }
            return Err(CmuxError::Command {
                message: response
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown error")
                    .to_string(),
                id: response.get("id").cloned(),
            });
        }
    }

    pub fn recv(&mut self) -> Result<Event> {
        if self.finished {
            return Err(CmuxError::Connection("stream is closed".to_string()));
        }
        if !self.buffered.is_empty() {
            let event = self.buffered.remove(0);
            return Ok(self.finish_terminal(event));
        }
        loop {
            let value = self.conn.recv()?;
            if value.get("event").is_some() {
                let event = parse_event(value);
                return Ok(self.finish_terminal(event));
            }
        }
    }

    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<Event> {
        if self.finished {
            return Err(CmuxError::Connection("stream is closed".to_string()));
        }
        if !self.buffered.is_empty() {
            let event = self.buffered.remove(0);
            return Ok(self.finish_terminal(event));
        }
        let event = self.conn.with_read_timeout(timeout, |conn| {
            loop {
                let value = conn.recv()?;
                if value.get("event").is_some() {
                    return Ok(parse_event(value));
                }
            }
        })?;
        Ok(self.finish_terminal(event))
    }

    pub fn close(&mut self) {
        if self.finished {
            return;
        }
        self.finished = true;
        let _ = self.conn.writer.shutdown(Shutdown::Both);
    }

    fn finish_terminal(&mut self, event: Event) -> Event {
        if matches!(
            &event,
            Event::Detached(_) | Event::Overflow(_) | Event::TopologyResnapshotRequired(_)
        ) {
            self.finished = true;
            let _ = self.conn.writer.shutdown(Shutdown::Both);
        }
        event
    }
}

pub struct TopologyStream {
    stream: CmuxStream,
    cursor: TopologyCursor,
}

impl TopologyStream {
    pub fn cursor(&self) -> TopologyCursor {
        self.cursor.clone()
    }

    pub fn recv(&mut self) -> Result<TopologyStreamEvent> {
        let event = self.stream.recv()?;
        self.accept(event)
    }

    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<TopologyStreamEvent> {
        let event = self.stream.recv_timeout(timeout)?;
        self.accept(event)
    }

    pub fn close(&mut self) {
        self.stream.close();
    }

    fn accept(&mut self, event: Event) -> Result<TopologyStreamEvent> {
        match event {
            Event::TopologyDelta(delta) => {
                if let Some(required) = validate_topology_delta(&self.cursor, &delta) {
                    self.stream.close();
                    return Ok(TopologyStreamEvent::ResnapshotRequired(required));
                }
                self.cursor.revision = delta.revision;
                Ok(TopologyStreamEvent::Delta(delta))
            }
            Event::TopologyResnapshotRequired(required) => {
                self.stream.close();
                Ok(TopologyStreamEvent::ResnapshotRequired(required))
            }
            Event::Unknown(value) => {
                self.stream.close();
                Err(CmuxError::Decode(format!(
                    "unexpected topology stream event {}",
                    value.get("event").and_then(Value::as_str).unwrap_or("<missing>")
                )))
            }
            other => {
                self.stream.close();
                Err(CmuxError::Decode(format!("unexpected topology stream event {other:?}")))
            }
        }
    }
}

impl Iterator for TopologyStream {
    type Item = Result<TopologyStreamEvent>;

    fn next(&mut self) -> Option<Self::Item> {
        (!self.stream.finished).then(|| self.recv())
    }
}

impl Iterator for CmuxStream {
    type Item = Result<Event>;

    fn next(&mut self) -> Option<Self::Item> {
        (!self.finished).then(|| self.recv())
    }
}

struct JsonLineConnection {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
}

impl JsonLineConnection {
    fn connect(socket_path: &PathBuf, timeout: Duration) -> Result<Self> {
        let stream = UnixStream::connect(socket_path).map_err(|err| {
            CmuxError::Connection(format!(
                "cannot connect to session socket {}: {err}",
                socket_path.display()
            ))
        })?;
        stream
            .set_read_timeout(Some(timeout))
            .map_err(|err| CmuxError::Connection(format!("set read timeout failed: {err}")))?;
        stream
            .set_write_timeout(Some(timeout))
            .map_err(|err| CmuxError::Connection(format!("set write timeout failed: {err}")))?;
        let writer = stream
            .try_clone()
            .map_err(|err| CmuxError::Connection(format!("socket clone failed: {err}")))?;
        Ok(Self { writer, reader: BufReader::new(stream) })
    }

    fn send(&mut self, value: &Value) -> Result<()> {
        let mut encoded =
            serde_json::to_vec(value).map_err(|err| CmuxError::Decode(err.to_string()))?;
        encoded.push(b'\n');
        self.writer
            .write_all(&encoded)
            .map_err(|err| CmuxError::Connection(format!("socket write failed: {err}")))
    }

    fn recv(&mut self) -> Result<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Err(CmuxError::Connection("session socket closed".to_string())),
            Ok(_) => serde_json::from_str(&line).map_err(|err| CmuxError::Decode(err.to_string())),
            Err(err)
                if err.kind() == std::io::ErrorKind::WouldBlock
                    || err.kind() == std::io::ErrorKind::TimedOut =>
            {
                Err(CmuxError::Timeout("session did not respond".to_string()))
            }
            Err(err) => Err(CmuxError::Connection(format!("socket read failed: {err}"))),
        }
    }

    fn with_read_timeout<T>(
        &mut self,
        timeout: Duration,
        operation: impl FnOnce(&mut Self) -> Result<T>,
    ) -> Result<T> {
        let previous =
            self.reader.get_ref().read_timeout().map_err(|err| {
                CmuxError::Connection(format!("read timeout lookup failed: {err}"))
            })?;
        self.reader
            .get_ref()
            .set_read_timeout(Some(timeout))
            .map_err(|err| CmuxError::Connection(format!("set read timeout failed: {err}")))?;
        let result = operation(self);
        let restore =
            self.reader.get_ref().set_read_timeout(previous).map_err(|err| {
                CmuxError::Connection(format!("restore read timeout failed: {err}"))
            });
        match (result, restore) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(err), _) => Err(err),
            (Ok(_), Err(err)) => Err(err),
        }
    }
}

#[derive(Debug, Deserialize)]
struct Empty {}

fn parse_event(value: Value) -> Event {
    let event = value.get("event").and_then(Value::as_str).unwrap_or_default();
    match event {
        "tree-changed" => Event::TreeChanged,
        "layout-changed" => parse_typed(value).map_or_else(Event::Unknown, Event::LayoutChanged),
        "surface-output" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceOutput),
        "surface-resized" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceResized),
        "surface-resize-failed" => {
            parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceResizeFailed)
        }
        "surface-exited" => parse_typed(value).map_or_else(Event::Unknown, Event::SurfaceExited),
        "title-changed" => parse_typed(value).map_or_else(Event::Unknown, Event::TitleChanged),
        "bell" => parse_typed(value).map_or_else(Event::Unknown, Event::Bell),
        "empty" => Event::Empty,
        "vt-state" => parse_typed(value).map_or_else(Event::Unknown, Event::VtState),
        "output" => parse_typed(value).map_or_else(Event::Unknown, Event::Output),
        "resized" => parse_typed(value).map_or_else(Event::Unknown, Event::Resized),
        "detached" => parse_typed(value).map_or_else(Event::Unknown, Event::Detached),
        "overflow" => parse_typed(value).map_or_else(Event::Unknown, Event::Overflow),
        "topology-delta" => parse_typed(value).map_or_else(Event::Unknown, Event::TopologyDelta),
        "topology-resnapshot-required" => {
            parse_typed(value).map_or_else(Event::Unknown, Event::TopologyResnapshotRequired)
        }
        _ => Event::Unknown(value),
    }
}

fn parse_typed<T: for<'de> Deserialize<'de>>(value: Value) -> std::result::Result<T, Value> {
    serde_json::from_value(value.clone()).map_err(|_| value)
}

fn surface_params(surface: u64) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("surface".to_string(), Value::from(surface));
    params
}

fn insert_opt<T: Serialize>(params: &mut Map<String, Value>, key: &str, value: Option<T>) {
    if let Some(value) = value {
        params.insert(
            key.to_string(),
            serde_json::to_value(value).expect("serializing command parameter must not fail"),
        );
    }
}

fn topology_fence_failure(
    cursor: TopologyCursor,
    daemon_instance_id: Uuid,
    session_id: Uuid,
    current_revision: u64,
) -> TopologyResnapshotRequired {
    let reason = if daemon_instance_id != cursor.daemon_instance_id {
        TopologyResnapshotReason::StaleDaemon
    } else if session_id != cursor.session_id {
        TopologyResnapshotReason::StaleSession
    } else {
        TopologyResnapshotReason::HistoryGap
    };
    TopologyResnapshotRequired {
        daemon_instance_id,
        session_id,
        current_revision: Some(current_revision),
        reason,
    }
}

fn validate_topology_delta(
    cursor: &TopologyCursor,
    delta: &TopologyDelta,
) -> Option<TopologyResnapshotRequired> {
    if delta.daemon_instance_id != cursor.daemon_instance_id
        || delta.session_id != cursor.session_id
        || delta.base_revision != cursor.revision
        || delta.base_revision.checked_add(1) != Some(delta.revision)
    {
        Some(topology_fence_failure(
            cursor.clone(),
            delta.daemon_instance_id.clone(),
            delta.session_id.clone(),
            delta.revision,
        ))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn topology_vectors() -> Value {
        serde_json::from_str(include_str!("../../conformance/topology-v8.json")).unwrap()
    }

    #[test]
    fn protocol_v8_shared_vectors_decode_typed_uuid_topology_and_recovery() {
        let vectors = topology_vectors();
        let identity: IdentifyResult = serde_json::from_value(vectors["identify"].clone()).unwrap();
        assert_eq!(identity.topology_revision, Some(47));
        assert_eq!(identity.topology_cursor().unwrap().revision, 41);
        let ping: PingResult = serde_json::from_value(vectors["ping"].clone()).unwrap();
        assert!(ping.ok);
        assert_eq!(ping.canonical_topology_revision, Some(41));
        assert_eq!(ping.topology_revision, Some(47));
        let snapshot: TopologySnapshot =
            serde_json::from_value(vectors["snapshot"].clone()).unwrap();
        assert_eq!(snapshot.revision, 41);
        assert_eq!(snapshot.topology.workspaces[0].screens[0].panes[0].tabs[0].id, 4);

        let delta = match parse_event(vectors["delta"].clone()) {
            Event::TopologyDelta(delta) => delta,
            event => panic!("unexpected event {event:?}"),
        };
        assert_eq!(delta.operation, TopologyOperation::WorkspaceRenamed);
        assert!(validate_topology_delta(&snapshot.cursor(), &delta).is_none());

        let reasons = vectors["resnapshot_results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| {
                serde_json::from_value::<TopologyResnapshotRequired>(value.clone()).unwrap().reason
            })
            .collect::<Vec<_>>();
        assert_eq!(
            reasons,
            vec![
                TopologyResnapshotReason::StaleDaemon,
                TopologyResnapshotReason::StaleSession,
                TopologyResnapshotReason::RevisionAhead,
                TopologyResnapshotReason::HistoryGap,
                TopologyResnapshotReason::ReplayTooLarge,
            ]
        );
        assert!(matches!(
            parse_event(vectors["slow_consumer_event"].clone()),
            Event::TopologyResnapshotRequired(TopologyResnapshotRequired {
                current_revision: None,
                reason: TopologyResnapshotReason::SlowConsumer,
                ..
            })
        ));
    }

    #[test]
    fn topology_delta_fence_synthesizes_explicit_resnapshot() {
        let vectors = topology_vectors();
        let snapshot: TopologySnapshot =
            serde_json::from_value(vectors["snapshot"].clone()).unwrap();
        let mut delta: TopologyDelta = serde_json::from_value(vectors["delta"].clone()).unwrap();
        delta.base_revision += 1;
        let required = validate_topology_delta(&snapshot.cursor(), &delta).unwrap();
        assert_eq!(required.reason, TopologyResnapshotReason::HistoryGap);
    }

    #[test]
    fn darwin_default_socket_path_accepts_103_bytes_and_falls_back_at_104() {
        let base = PathBuf::from("/tmp/runtime");
        let uid = "42";
        let empty_session = base.join("cmux-tui-42").join(".sock");
        let session = "s".repeat(103 - socket_path_bytes(&empty_session));

        let accepted = default_socket_path_from(&base, uid, &session, Some(103));
        assert_eq!(socket_path_bytes(&accepted), 103);
        assert!(accepted.starts_with(&base));

        let fallback = default_socket_path_from(&base, uid, &format!("{session}s"), Some(103));
        assert!(fallback.starts_with("/tmp/cmux-tui-42"));
        assert!(!fallback.starts_with(&base));
    }

    #[test]
    fn title_changed_decodes_authoritative_title() {
        let event = parse_event(serde_json::json!({
            "event": "title-changed",
            "surface": 7,
            "title": "build logs",
        }));

        assert!(matches!(
            event,
            Event::TitleChanged(TitleChangedEvent { surface: 7, title })
                if title.as_deref() == Some("build logs")
        ));

        let legacy = parse_event(serde_json::json!({
            "event": "title-changed",
            "surface": 7,
        }));
        assert!(matches!(
            legacy,
            Event::TitleChanged(TitleChangedEvent { surface: 7, title: None })
        ));
    }

    #[test]
    fn resized_decodes_protocol_v6_data_field() {
        let event = parse_event(serde_json::json!({
            "event": "resized",
            "surface": 7,
            "cols": 80,
            "rows": 24,
            "data": "cmVwbGF5",
        }));

        assert!(matches!(
            event,
            Event::Resized(ResizedEvent { surface: 7, replay, .. }) if replay == "cmVwbGF5"
        ));
    }

    #[test]
    fn surface_resize_failed_decodes_retry_schedule() {
        let event = parse_event(serde_json::json!({
            "event": "surface-resize-failed",
            "surface": 7,
            "cols": 120,
            "rows": 40,
            "error": "browser is not responding",
            "retry_after_ms": 250,
        }));

        assert!(matches!(
            event,
            Event::SurfaceResizeFailed(SurfaceResizeFailedEvent {
                surface: 7,
                cols: 120,
                rows: 40,
                error,
                retry_after_ms: Some(250),
                reservation_id: None,
            }) if error == "browser is not responding"
        ));
    }

    #[test]
    fn legacy_resize_response_defaults_to_accepted() {
        let result: ResizeSurfaceResult = serde_json::from_value(serde_json::json!({})).unwrap();
        assert!(result.accepted);
        assert_eq!(result.reservation_id, None);
        let reserved: ResizeSurfaceResult =
            serde_json::from_value(serde_json::json!({"accepted": true, "reservation_id": 41}))
                .unwrap();
        assert_eq!(reserved.reservation_id, Some(41));
    }

    #[test]
    fn process_info_decodes_argv_and_canonical_tty() {
        let result: ProcessInfoResult = serde_json::from_value(serde_json::json!({
            "pid": 42,
            "command": ["/bin/zsh", "-l"],
            "cwd": "/tmp",
            "tty": "/dev/ttys004",
        }))
        .unwrap();
        assert_eq!(result.pid, Some(42));
        assert_eq!(result.command, Some(vec!["/bin/zsh".into(), "-l".into()]));
        assert_eq!(result.cwd.as_deref(), Some("/tmp"));
        assert_eq!(result.tty.as_deref(), Some("/dev/ttys004"));
        assert!(
            serde_json::from_value::<ProcessInfoResult>(serde_json::json!({
                "pid": 42,
                "command": "/bin/zsh -l",
                "cwd": null,
                "tty": null,
            }))
            .is_err()
        );
    }

    #[test]
    fn ensure_terminal_wire_includes_wait_policy_and_decodes_stable_placement() {
        let options = EnsureTerminalOptions {
            argv: Some(vec!["/bin/zsh".into(), "-l".into()]),
            env: vec![EnsureTerminalEnvironment { name: "CMUX_TEST".into(), value: "1".into() }],
            wait_after_command: true,
            ..EnsureTerminalOptions::default()
        };
        let encoded = serde_json::to_value(&options).unwrap();
        assert_eq!(encoded["wait_after_command"], true);
        assert_eq!(encoded["env"][0]["name"], "CMUX_TEST");

        let result: EnsureTerminalResult = serde_json::from_value(serde_json::json!({
            "created": true,
            "workspace": 1,
            "workspace_uuid": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "screen": 2,
            "screen_uuid": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "pane": 3,
            "pane_uuid": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            "surface": 4,
            "surface_uuid": "ffffffff-ffff-4fff-8fff-ffffffffffff",
        }))
        .unwrap();
        assert!(result.created);
        assert_eq!(result.surface, 4);
        assert_eq!(result.surface_uuid.as_str(), "ffffffff-ffff-4fff-8fff-ffffffffffff");
    }

    #[test]
    fn reparent_terminal_decodes_stable_placement() {
        let result: ReparentTerminalResult = serde_json::from_value(serde_json::json!({
            "moved": true,
            "workspace": 1,
            "workspace_uuid": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            "screen": 2,
            "screen_uuid": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            "pane": 3,
            "pane_uuid": "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            "surface": 4,
            "surface_uuid": "ffffffff-ffff-4fff-8fff-ffffffffffff",
        }))
        .unwrap();
        assert!(result.moved);
        assert_eq!(result.surface, 4);
        assert_eq!(result.surface_uuid.as_str(), "ffffffff-ffff-4fff-8fff-ffffffffffff");
    }

    #[test]
    fn overflow_decodes_recovery_fields() {
        let event = parse_event(serde_json::json!({
            "event": "overflow",
            "error": "subscriber fell behind",
            "scope": "surface",
            "surface": 7,
        }));

        assert!(matches!(
            event,
            Event::Overflow(OverflowEvent { error, scope, surface })
                if error == "subscriber fell behind"
                    && scope.as_deref() == Some("surface")
                    && surface == Some(7)
        ));
    }

    #[test]
    fn iterator_yields_buffered_overflow_once_then_stops() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let writer = socket.try_clone().unwrap();
        let mut stream = CmuxStream {
            conn: JsonLineConnection { writer, reader: BufReader::new(socket) },
            buffered: vec![Event::Overflow(OverflowEvent {
                error: "fell behind".to_string(),
                scope: None,
                surface: None,
            })],
            finished: false,
        };

        assert!(matches!(stream.next(), Some(Ok(Event::Overflow(_)))));
        assert!(stream.next().is_none());
    }
}

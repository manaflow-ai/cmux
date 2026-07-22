use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::fmt;
use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

pub type Result<T> = std::result::Result<T, CmuxError>;

#[derive(Debug)]
pub enum CmuxError {
    Command { message: String, id: Option<Value> },
    Decode(String),
    Connection(String),
    Timeout(String),
    ProtocolVersion(String),
    InvalidArgument(String),
}

impl fmt::Display for CmuxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Command { message, .. } => write!(f, "{message}"),
            Self::Decode(message)
            | Self::Connection(message)
            | Self::Timeout(message)
            | Self::ProtocolVersion(message)
            | Self::InvalidArgument(message) => write!(f, "{message}"),
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
    let base = std::env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join(format!("cmux-tui-{}", current_uid_component())).join(format!("{session}.sock"))
}

#[cfg(unix)]
fn current_uid_component() -> String {
    unsafe { libc::getuid() }.to_string()
}

#[cfg(not(unix))]
fn current_uid_component() -> String {
    std::env::var("USERNAME").or_else(|_| std::env::var("USER")).unwrap_or_else(|_| "0".to_string())
}

#[derive(Debug, Clone, Deserialize)]
pub struct IdentifyResult {
    pub app: String,
    pub version: String,
    pub protocol: u32,
    pub session: String,
    pub pid: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct IdentifyDetails {
    pub app: String,
    pub version: String,
    pub build_commit: Option<String>,
    pub ghostty_commit: Option<String>,
    pub protocol: u32,
    #[serde(default)]
    pub capabilities: Vec<String>,
    pub session: String,
    pub pid: u32,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SurfaceResult {
    pub surface: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspacePlacement {
    pub workspace: u64,
    pub key: String,
    pub index: usize,
    pub workspace_revision: u64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TerminalPlacement {
    pub surface: u64,
    pub pane: u64,
    pub screen: u64,
    pub workspace: u64,
    pub key: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WorkspaceMutation {
    pub workspace: u64,
    pub key: String,
    pub workspace_revision: u64,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CreateWorkspaceOptions<'a> {
    pub name: Option<&'a str>,
    pub key: Option<&'a str>,
    pub expected_revision: Option<u64>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CreateTerminalOptions<'a> {
    pub workspace: Option<u64>,
    pub key: Option<&'a str>,
    pub argv: Option<&'a [String]>,
    pub command: Option<&'a str>,
    pub cwd: Option<&'a str>,
    pub name: Option<&'a str>,
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct WorkspaceSelectorOptions<'a> {
    pub workspace: Option<u64>,
    pub key: Option<&'a str>,
    pub expected_revision: Option<u64>,
}

fn validate_workspace_selector(workspace: Option<u64>, key: Option<&str>) -> Result<()> {
    if workspace.is_none() && key.is_none_or(|key| key.trim().is_empty()) {
        return Err(CmuxError::InvalidArgument("workspace or key is required".to_string()));
    }
    if key.is_some_and(|key| key.trim().is_empty()) {
        return Err(CmuxError::InvalidArgument("workspace key cannot be empty".to_string()));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, Default)]
pub struct AttachSurfaceOptions {
    pub cols: Option<u16>,
    pub rows: Option<u16>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReadScreenResult {
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VtStateResult {
    pub cols: u16,
    pub rows: u16,
    pub data: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Tree {
    #[serde(default)]
    pub workspace_revision: u64,
    #[serde(default)]
    pub pane_revision: Option<u64>,
    pub workspaces: Vec<Workspace>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Workspace {
    pub id: u64,
    #[serde(default)]
    pub key: String,
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
    Split {
        /// Stable split id, present on protocol v8 and newer servers.
        #[serde(default)]
        split: Option<u64>,
        dir: String,
        ratio: f32,
        a: Box<Layout>,
        b: Box<Layout>,
    },
    #[serde(rename = "stack")]
    Stack { panes: Vec<u64>, expanded: u64 },
}

#[derive(Debug, Clone, Deserialize)]
pub struct Pane {
    pub id: u64,
    pub name: Option<String>,
    #[serde(default)]
    pub active_tab: usize,
    #[serde(default)]
    pub focused_at: u64,
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
    Unknown(Value),
}

pub struct CmuxClient {
    config: ClientConfig,
    conn: JsonLineConnection,
    next_id: u64,
    protocol: Option<u32>,
    capabilities: Vec<String>,
}

impl CmuxClient {
    pub fn connect(config: ClientConfig) -> Result<Self> {
        let conn = JsonLineConnection::connect(&config.socket_path, config.timeout)?;
        Ok(Self { config, conn, next_id: 1, protocol: None, capabilities: Vec::new() })
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
        let details: IdentifyDetails = self.request("identify", Map::new())?;
        self.protocol = Some(details.protocol);
        self.capabilities.clone_from(&details.capabilities);
        Ok(IdentifyResult {
            app: details.app,
            version: details.version,
            protocol: details.protocol,
            session: details.session,
            pid: details.pid,
        })
    }

    /// Identify the server with optional immutable build revisions.
    pub fn identify_details(&mut self) -> Result<IdentifyDetails> {
        let result: IdentifyDetails = self.request("identify", Map::new())?;
        self.protocol = Some(result.protocol);
        self.capabilities.clone_from(&result.capabilities);
        Ok(result)
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

    pub fn create_workspace(
        &mut self,
        options: CreateWorkspaceOptions<'_>,
    ) -> Result<WorkspacePlacement> {
        self.require_capability("workspace-registry-v1", "workspace registry")?;
        let mut params = Map::new();
        insert_opt(&mut params, "name", options.name);
        insert_opt(&mut params, "key", options.key);
        insert_opt(&mut params, "expected_revision", options.expected_revision);
        self.request("create-workspace", params)
    }

    pub fn create_terminal(
        &mut self,
        options: CreateTerminalOptions<'_>,
    ) -> Result<TerminalPlacement> {
        validate_workspace_selector(options.workspace, options.key)?;
        self.require_capability("workspace-registry-v1", "workspace registry")?;
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", options.workspace);
        insert_opt(&mut params, "key", options.key);
        insert_opt(&mut params, "argv", options.argv);
        insert_opt(&mut params, "command", options.command);
        insert_opt(&mut params, "cwd", options.cwd);
        insert_opt(&mut params, "name", options.name);
        insert_opt(&mut params, "cols", options.cols);
        insert_opt(&mut params, "rows", options.rows);
        self.request("create-terminal", params)
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

    pub fn new_pane(
        &mut self,
        pane: u64,
        cols: Option<u16>,
        rows: Option<u16>,
    ) -> Result<SurfaceResult> {
        self.require_protocol(9, "new-pane")?;
        let mut params = Map::new();
        params.insert("pane".to_string(), Value::from(pane));
        insert_opt(&mut params, "cols", cols);
        insert_opt(&mut params, "rows", rows);
        self.request("new-pane", params)
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

    pub fn set_split_ratio(&mut self, split: u64, ratio: f32) -> Result<()> {
        self.require_protocol(8, "set-split-ratio")?;
        let mut params = Map::new();
        params.insert("split".to_string(), Value::from(split));
        params.insert("ratio".to_string(), Value::from(ratio));
        self.request::<Empty>("set-split-ratio", params).map(|_| ())
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

    pub fn close_workspace_registry(
        &mut self,
        options: WorkspaceSelectorOptions<'_>,
    ) -> Result<WorkspaceMutation> {
        validate_workspace_selector(options.workspace, options.key)?;
        self.require_capability("workspace-registry-v1", "workspace registry")?;
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", options.workspace);
        insert_opt(&mut params, "key", options.key);
        insert_opt(&mut params, "expected_revision", options.expected_revision);
        self.request("close-workspace", params)
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

    pub fn rename_workspace_registry(
        &mut self,
        options: WorkspaceSelectorOptions<'_>,
        name: &str,
    ) -> Result<WorkspaceMutation> {
        validate_workspace_selector(options.workspace, options.key)?;
        self.require_capability("workspace-registry-v1", "workspace registry")?;
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", options.workspace);
        insert_opt(&mut params, "key", options.key);
        insert_opt(&mut params, "expected_revision", options.expected_revision);
        params.insert("name".to_string(), Value::from(name));
        self.request("rename-workspace", params)
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

    pub fn move_workspace_registry(
        &mut self,
        options: WorkspaceSelectorOptions<'_>,
        index: usize,
    ) -> Result<WorkspaceMutation> {
        validate_workspace_selector(options.workspace, options.key)?;
        self.require_capability("workspace-registry-v1", "workspace registry")?;
        let mut params = Map::new();
        insert_opt(&mut params, "workspace", options.workspace);
        insert_opt(&mut params, "key", options.key);
        insert_opt(&mut params, "expected_revision", options.expected_revision);
        params.insert("index".to_string(), Value::from(index));
        self.request("move-workspace", params)
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
        self.attach_surface_with_options(surface, AttachSurfaceOptions::default())
    }

    pub fn attach_surface_with_options(
        &mut self,
        surface: u64,
        options: AttachSurfaceOptions,
    ) -> Result<CmuxStream> {
        if options.cols.is_some() != options.rows.is_some() {
            return Err(CmuxError::InvalidArgument(
                "attach-surface cols and rows must be supplied together".to_string(),
            ));
        }
        let protocol = match self.protocol {
            Some(protocol) => protocol,
            None => self.identify()?.protocol,
        };
        if protocol > 5 && !self.config.allow_protocol_v6_attach {
            return Err(CmuxError::ProtocolVersion(format!(
                "unsupported attach protocol {protocol}"
            )));
        }
        if (options.cols.is_some() || options.rows.is_some())
            && !self.capabilities.iter().any(|value| value == "attach-initial-size")
        {
            return Err(CmuxError::ProtocolVersion(
                "initial attach sizing is not supported by this server".to_string(),
            ));
        }
        let mut params = surface_params(surface);
        insert_opt(&mut params, "cols", options.cols);
        insert_opt(&mut params, "rows", options.rows);
        self.open_stream("attach-surface", params)
    }

    fn require_capability(&mut self, capability: &str, feature: &str) -> Result<()> {
        if self.protocol.is_none() {
            self.identify()?;
        }
        if self.capabilities.iter().any(|value| value == capability) {
            return Ok(());
        }
        Err(CmuxError::ProtocolVersion(format!("{feature} is not supported by this server")))
    }

    fn require_protocol(&mut self, minimum: u32, feature: &str) -> Result<()> {
        let protocol = match self.protocol {
            Some(protocol) => protocol,
            None => self.identify()?.protocol,
        };
        if protocol < minimum {
            return Err(CmuxError::ProtocolVersion(format!(
                "{feature} requires protocol {minimum}; server uses protocol {protocol}"
            )));
        }
        Ok(())
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
                return Ok(Self { conn, buffered, finished: false });
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

    fn finish_terminal(&mut self, event: Event) -> Event {
        if matches!(&event, Event::Detached(_) | Event::Overflow(_)) {
            self.finished = true;
            let _ = self.conn.writer.shutdown(Shutdown::Both);
        }
        event
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identify_preserves_legacy_shape_and_exposes_optional_details() {
        let wire = serde_json::json!({
            "app": "cmux-tui",
            "version": "0.1.2",
            "build_commit": "cmux-sha",
            "ghostty_commit": "ghostty-sha",
            "protocol": 7,
            "session": "main",
            "pid": 42,
        });
        let legacy: IdentifyResult = serde_json::from_value(wire.clone()).unwrap();
        let IdentifyResult { app, version, protocol, session, pid } = legacy;
        assert_eq!(
            (app.as_str(), version.as_str(), protocol, session.as_str(), pid),
            ("cmux-tui", "0.1.2", 7, "main", 42)
        );

        let details: IdentifyDetails = serde_json::from_value(wire).unwrap();
        assert_eq!(details.build_commit.as_deref(), Some("cmux-sha"));
        assert_eq!(details.ghostty_commit.as_deref(), Some("ghostty-sha"));
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
    fn legacy_tree_defaults_additive_workspace_registry_fields() {
        let tree: Tree = serde_json::from_value(serde_json::json!({
            "workspaces": [{
                "id": 1,
                "name": "one",
                "active": true,
                "screens": [],
            }],
        }))
        .unwrap();

        assert_eq!(tree.workspace_revision, 0);
        assert_eq!(tree.pane_revision, None);
        assert_eq!(tree.workspaces[0].key, "");
    }

    #[test]
    fn tree_preserves_optional_pane_revision() {
        let tree: Tree = serde_json::from_value(serde_json::json!({
            "pane_revision": 7,
            "workspaces": [],
        }))
        .unwrap();

        assert_eq!(tree.pane_revision, Some(7));
    }

    #[test]
    fn workspace_registry_placements_decode() {
        let workspace: WorkspacePlacement = serde_json::from_value(serde_json::json!({
            "workspace": 1,
            "key": "stable-key",
            "index": 0,
            "workspace_revision": 4,
        }))
        .unwrap();
        assert_eq!(workspace.workspace_revision, 4);

        let terminal: TerminalPlacement = serde_json::from_value(serde_json::json!({
            "surface": 5,
            "pane": 4,
            "screen": 3,
            "workspace": 1,
            "key": "stable-key",
        }))
        .unwrap();
        assert_eq!(terminal.key, "stable-key");

        let mutation: WorkspaceMutation = serde_json::from_value(serde_json::json!({
            "workspace": 1,
            "key": "stable-key",
            "workspace_revision": 5,
        }))
        .unwrap();
        assert_eq!(mutation.workspace_revision, 5);
    }

    #[test]
    fn workspace_registry_selectors_reject_missing_and_empty_keys_locally() {
        assert!(matches!(
            validate_workspace_selector(None, None),
            Err(CmuxError::InvalidArgument(message)) if message == "workspace or key is required"
        ));
        assert!(matches!(
            validate_workspace_selector(None, Some("  ")),
            Err(CmuxError::InvalidArgument(message)) if message == "workspace or key is required"
        ));
        validate_workspace_selector(Some(1), None).unwrap();
        validate_workspace_selector(None, Some("stable")).unwrap();
    }

    #[test]
    fn attach_surface_rejects_partial_initial_size_locally() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let writer = socket.try_clone().unwrap();
        let mut client = CmuxClient {
            config: ClientConfig::default(),
            conn: JsonLineConnection { writer, reader: BufReader::new(socket) },
            next_id: 1,
            protocol: Some(5),
            capabilities: Vec::new(),
        };
        assert!(matches!(
            client.attach_surface_with_options(
                1,
                AttachSurfaceOptions { cols: Some(80), rows: None },
            ),
            Err(CmuxError::InvalidArgument(message))
                if message == "attach-surface cols and rows must be supplied together"
        ));
    }

    #[test]
    fn stack_layout_decodes_protocol_v9_shape() {
        let layout: Layout = serde_json::from_value(serde_json::json!({
            "type": "stack",
            "panes": [1, 2, 3],
            "expanded": 2,
        }))
        .unwrap();
        assert!(matches!(
            layout,
            Layout::Stack { panes, expanded } if panes == vec![1, 2, 3] && expanded == 2
        ));
    }

    #[test]
    fn set_split_ratio_requires_protocol_eight() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let writer = socket.try_clone().unwrap();
        let mut client = CmuxClient {
            config: ClientConfig::default(),
            conn: JsonLineConnection { writer, reader: BufReader::new(socket) },
            next_id: 1,
            protocol: Some(7),
            capabilities: Vec::new(),
        };
        let error = client.require_protocol(8, "set-split-ratio").unwrap_err();
        assert_eq!(
            error.to_string(),
            "set-split-ratio requires protocol 8; server uses protocol 7"
        );
    }

    #[test]
    fn set_split_ratio_accepts_newer_additive_protocols() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let writer = socket.try_clone().unwrap();
        let mut client = CmuxClient {
            config: ClientConfig::default(),
            conn: JsonLineConnection { writer, reader: BufReader::new(socket) },
            next_id: 1,
            protocol: Some(9),
            capabilities: Vec::new(),
        };
        client.require_protocol(8, "set-split-ratio").unwrap();
    }

    #[test]
    fn new_pane_requires_protocol_nine() {
        let (socket, _peer) = UnixStream::pair().unwrap();
        let writer = socket.try_clone().unwrap();
        let mut client = CmuxClient {
            config: ClientConfig::default(),
            conn: JsonLineConnection { writer, reader: BufReader::new(socket) },
            next_id: 1,
            protocol: Some(8),
            capabilities: Vec::new(),
        };
        let error = client.require_protocol(9, "new-pane").unwrap_err();
        assert_eq!(error.to_string(), "new-pane requires protocol 9; server uses protocol 8");
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

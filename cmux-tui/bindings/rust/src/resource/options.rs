use super::id::*;
use super::model::{Cursor, LayoutDocument};
use super::typed_stream::{ColorHex, JournalClass, JournalSensitivity};
use crate::{Error, Result};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Cloneable cancellation signal for one or more explicitly scoped calls.
#[derive(Clone, Default)]
pub struct CancellationToken {
    canceled: Arc<AtomicBool>,
}

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.canceled.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.canceled.load(Ordering::Acquire)
    }
}

impl std::fmt::Debug for CancellationToken {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CancellationToken")
            .field("cancelled", &self.is_cancelled())
            .finish()
    }
}

/// Local deadline and cancellation policy for exactly one SDK call.
#[derive(Clone, Debug, Default)]
pub struct RequestOptions {
    pub timeout: Option<Duration>,
    pub cancellation: Option<CancellationToken>,
}

impl RequestOptions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Result<Self> {
        if timeout.is_zero() {
            return Err(Error::InvalidArgument(
                "request timeout must be greater than zero".to_string(),
            ));
        }
        self.timeout = Some(timeout);
        Ok(self)
    }

    pub fn with_cancellation(mut self, cancellation: CancellationToken) -> Self {
        self.cancellation = Some(cancellation);
        self
    }

    pub(crate) fn merged_over(&self, fallback: &Self) -> Self {
        Self {
            timeout: self.timeout.or(fallback.timeout),
            cancellation: self.cancellation.clone().or_else(|| fallback.cancellation.clone()),
        }
    }

    pub(crate) fn validate(&self) -> Result<()> {
        if self.timeout.is_some_and(|timeout| timeout.is_zero()) {
            return Err(Error::InvalidArgument(
                "request timeout must be greater than zero".to_string(),
            ));
        }
        Ok(())
    }
}

/// Idempotency and optimistic-concurrency policy for one mutation.
///
/// The SDK never retries mutations. Reuse the same value explicitly when
/// retrying an operation whose outcome is unknown.
#[derive(Clone, Debug)]
pub struct MutationOptions {
    pub idempotency_key: String,
    pub expected_revision: Option<u64>,
    pub request: RequestOptions,
}

pub(crate) fn validate_idempotency_key(idempotency_key: &str) -> Result<()> {
    if idempotency_key.trim().is_empty() {
        return Err(Error::InvalidArgument(
            "idempotency key must contain at least one non-whitespace Unicode scalar".to_string(),
        ));
    }
    if idempotency_key.len() > 128 {
        return Err(Error::InvalidArgument(
            "idempotency key must contain 1 to 128 UTF-8 bytes".to_string(),
        ));
    }
    if idempotency_key.chars().any(char::is_control) {
        return Err(Error::InvalidArgument(
            "idempotency key must not contain Unicode control characters".to_string(),
        ));
    }
    Ok(())
}

impl MutationOptions {
    pub fn new(idempotency_key: impl Into<String>) -> Result<Self> {
        let idempotency_key = idempotency_key.into();
        validate_idempotency_key(&idempotency_key)?;
        Ok(Self { idempotency_key, expected_revision: None, request: RequestOptions::default() })
    }

    /// Generates a cryptographically random key for a single, non-retried call.
    pub fn unique() -> Result<Self> {
        let mut bytes = [0_u8; 16];
        getrandom::fill(&mut bytes).map_err(|error| {
            Error::Connection(format!("cannot allocate idempotency key: {error}"))
        })?;
        Ok(Self {
            idempotency_key: format!("rust-{}", encode_hex(bytes)),
            expected_revision: None,
            request: RequestOptions::default(),
        })
    }

    pub fn with_expected_revision(mut self, revision: u64) -> Self {
        self.expected_revision = Some(revision);
        self
    }

    pub fn with_request_options(mut self, request: RequestOptions) -> Self {
        self.request = request;
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Result<Self> {
        self.request = self.request.with_timeout(timeout)?;
        Ok(self)
    }

    pub fn with_cancellation(mut self, cancellation: CancellationToken) -> Self {
        self.request = self.request.with_cancellation(cancellation);
        self
    }
}

/// Exact executable and arguments, or a target-side shell script.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunCommand {
    Exact { argv: Vec<String> },
    Shell { script: String },
}

impl RunCommand {
    pub fn argv<I, S>(argv: I) -> Result<Self>
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let argv = argv.into_iter().map(Into::into).collect::<Vec<_>>();
        if argv.first().is_none_or(String::is_empty) {
            return Err(Error::InvalidArgument(
                "argv must contain a non-empty executable".to_string(),
            ));
        }
        Ok(Self::Exact { argv })
    }

    /// Requests evaluation by the target session's platform shell.
    pub fn shell(script: impl Into<String>) -> Result<Self> {
        let script = script.into();
        if script.is_empty() {
            return Err(Error::InvalidArgument("shell script must not be empty".to_string()));
        }
        Ok(Self::Shell { script })
    }

    /// Runs a specific shell executable without local `$SHELL` inspection.
    pub fn shell_executable(
        executable: impl Into<String>,
        script: impl Into<String>,
    ) -> Result<Self> {
        Self::argv([executable.into(), "-lc".to_string(), script.into()])
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
}

impl Size {
    pub fn new(cols: u16, rows: u16) -> Result<Self> {
        if cols == 0 || rows == 0 {
            return Err(Error::InvalidArgument(
                "terminal dimensions must be greater than zero".to_string(),
            ));
        }
        Ok(Self { cols, rows })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelSize {
    pub width_px: u32,
    pub height_px: u32,
}

impl PixelSize {
    pub fn new(width_px: u32, height_px: u32) -> Result<Self> {
        if width_px == 0 || height_px == 0 {
            return Err(Error::InvalidArgument(
                "pixel dimensions must be greater than zero".to_string(),
            ));
        }
        Ok(Self { width_px, height_px })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunOptions {
    pub command: RunCommand,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub size: Option<Size>,
    pub correlation_key: Option<String>,
}

impl RunOptions {
    pub fn command(command: RunCommand) -> Self {
        Self { command, cwd: None, name: None, size: None, correlation_key: None }
    }

    pub fn cwd(mut self, cwd: impl Into<String>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    pub fn size(mut self, size: Size) -> Self {
        self.size = Some(size);
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateWorkspaceOptions {
    pub name: Option<String>,
    pub initial_content: InitialContent,
    pub correlation_key: Option<String>,
}

impl Default for CreateWorkspaceOptions {
    fn default() -> Self {
        Self { name: None, initial_content: InitialContent::Terminal, correlation_key: None }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InitialContent {
    Terminal,
    Empty,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CreateScreenOptions {
    pub name: Option<String>,
    pub correlation_key: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CreatePaneOptions {
    pub cwd: Option<String>,
    pub size: Option<Size>,
    pub correlation_key: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

impl Direction {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Up => "up",
            Self::Down => "down",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SplitOptions {
    pub direction: Direction,
    pub ratio: Option<f64>,
    pub viewport_width: Option<f64>,
    pub cwd: Option<String>,
    pub size: Option<Size>,
    pub correlation_key: Option<String>,
}

impl SplitOptions {
    pub fn new(direction: Direction) -> Self {
        Self {
            direction,
            ratio: None,
            viewport_width: None,
            cwd: None,
            size: None,
            correlation_key: None,
        }
    }

    pub fn viewport_width(mut self, width: f64) -> Self {
        self.viewport_width = Some(width);
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SplitRatioOptions {
    pub split_id: SplitId,
    pub ratio: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ViewportWidthOptions {
    pub columns: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MoveDestination {
    pub workspace: Selector<WorkspaceId>,
    pub screen: Selector<ScreenId>,
    pub pane: Selector<PaneId>,
    pub index: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalProjectOptions {
    pub destination: MoveDestination,
    pub name: Option<String>,
}

impl TerminalProjectOptions {
    pub const fn new(destination: MoveDestination) -> Self {
        Self { destination, name: None }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaneSwapOptions {
    pub other_workspace: Selector<WorkspaceId>,
    pub other_screen: Selector<ScreenId>,
    pub other_pane: Selector<PaneId>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LabelOptions {
    /// `None` explicitly clears the optional name.
    pub name: Option<String>,
}

impl LabelOptions {
    pub fn set(name: impl Into<String>) -> Self {
        Self { name: Some(name.into()) }
    }

    pub const fn clear() -> Self {
        Self { name: None }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LayoutOptions {
    pub document: LayoutDocument,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UndoLayoutOptions {
    pub confirm_close: bool,
    pub confirmation_token: Option<String>,
}

impl UndoLayoutOptions {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.confirm_close && self.confirmation_token.is_none() {
            return Err(Error::InvalidArgument(
                "confirmation token is required when confirm_close is true".to_string(),
            ));
        }
        if let Some(token) = &self.confirmation_token
            && (token.is_empty() || token.len() > 128)
        {
            return Err(Error::InvalidArgument(
                "confirmation token must contain 1 to 128 UTF-8 bytes".to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ZoomOptions {
    pub enabled: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalCreateOptions {
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub size: Option<Size>,
    pub correlation_key: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowserCreateOptions {
    pub url: String,
    pub name: Option<String>,
    pub size: Option<PixelSize>,
    pub correlation_key: Option<String>,
}

impl BrowserCreateOptions {
    pub fn new(url: impl Into<String>) -> Self {
        Self { url: url.into(), name: None, size: None, correlation_key: None }
    }
}

pub(crate) fn validate_correlation_key(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > 128 {
        return Err(Error::InvalidArgument(
            "correlation key must contain 1 to 128 UTF-8 bytes".to_string(),
        ));
    }
    Ok(())
}

macro_rules! impl_correlation_key_builder {
    ($($options:ty),+ $(,)?) => {
        $(
            impl $options {
                pub fn correlation_key(mut self, value: impl Into<String>) -> Result<Self> {
                    let value = value.into();
                    validate_correlation_key(&value)?;
                    self.correlation_key = Some(value);
                    Ok(self)
                }
            }
        )+
    };
}

impl_correlation_key_builder!(
    RunOptions,
    CreateWorkspaceOptions,
    CreateScreenOptions,
    CreatePaneOptions,
    SplitOptions,
    TerminalCreateOptions,
    BrowserCreateOptions,
);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalKeysOptions {
    pub keys: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
}

impl MouseButton {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Middle => "middle",
            Self::Right => "right",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputModifier {
    Shift,
    Control,
    Alt,
    Meta,
}

impl InputModifier {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Shift => "shift",
            Self::Control => "control",
            Self::Alt => "alt",
            Self::Meta => "meta",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalMouseKind {
    Down,
    Up,
    Move,
    Wheel,
}

impl TerminalMouseKind {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
            Self::Move => "move",
            Self::Wheel => "wheel",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalMouseOptions {
    pub kind: TerminalMouseKind,
    pub row: u16,
    pub column: u16,
    pub button: Option<MouseButton>,
    pub delta_rows: Option<i32>,
    pub modifiers: Vec<InputModifier>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FocusInputOptions {
    pub focused: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReadScreenOptions;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReadHistoryOptions {
    pub before: Option<u64>,
    pub limit: Option<u32>,
    pub styled: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WaitOptions {
    pub pattern: String,
    pub timeout_ms: Option<u64>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CopyMode {
    Screen,
    Selection,
    Scrollback,
}

impl CopyMode {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Screen => "screen",
            Self::Selection => "selection",
            Self::Scrollback => "scrollback",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CopyOptions {
    pub mode: Option<CopyMode>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalAttachOptions {
    pub size: Option<Size>,
    pub read_only: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BrowserAttachOptions {
    pub size: Option<PixelSize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScrollOptions {
    pub delta_rows: i32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NavigateOptions {
    pub url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrowserKeyKind {
    Down,
    Up,
}

impl BrowserKeyKind {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowserKeyOptions {
    pub key: String,
    pub kind: Option<BrowserKeyKind>,
    pub modifiers: Vec<InputModifier>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextInputOptions {
    pub text: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrowserMouseKind {
    Down,
    Up,
    Move,
}

impl BrowserMouseKind {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Down => "down",
            Self::Up => "up",
            Self::Move => "move",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrowserMouseButton {
    Left,
    Middle,
    Right,
    Back,
    Forward,
}

impl BrowserMouseButton {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Middle => "middle",
            Self::Right => "right",
            Self::Back => "back",
            Self::Forward => "forward",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct BrowserMouseOptions {
    pub kind: BrowserMouseKind,
    pub x_px: f64,
    pub y_px: f64,
    pub pointer_frame_seq: u64,
    pub button: Option<BrowserMouseButton>,
    pub click_count: Option<u32>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WheelOptions {
    pub delta_x: f64,
    pub delta_y: f64,
    pub x_px: f64,
    pub y_px: f64,
    pub pointer_frame_seq: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientMetadataOptions {
    pub name: Update<String>,
    pub kind: Update<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Update<T> {
    #[default]
    Unchanged,
    Clear,
    Set(T),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientSizingOptions {
    pub enabled: bool,
    pub exclusive: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellPixelsOptions {
    pub width_px: u32,
    pub height_px: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CursorStyle {
    Block,
    Bar,
    Underline,
}

impl CursorStyle {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Bar => "bar",
            Self::Underline => "underline",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TerminalDefaultsOptions {
    pub foreground: Update<ColorHex>,
    pub background: Update<ColorHex>,
    pub cursor: Update<ColorHex>,
    pub selection_background: Update<ColorHex>,
    pub selection_foreground: Update<ColorHex>,
    pub cursor_style: Update<CursorStyle>,
    pub cursor_blink: Update<bool>,
    pub palette: Update<BTreeMap<u8, ColorHex>>,
    pub complete: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectionOptions {
    pub frontend_id: String,
    pub window_id: String,
    pub generation: String,
    pub projection: Value,
    pub expected_projection_revision: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PairingDecision {
    Accept,
    Reject,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingResolveOptions {
    pub decision: PairingDecision,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NotificationLevel {
    Info,
    Warning,
    Error,
}

impl NotificationLevel {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NotificationOptions {
    pub title: String,
    pub body: String,
    pub level: Option<NotificationLevel>,
    pub terminal_id: Option<TerminalId>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NotificationListOptions {
    pub limit: Option<u32>,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl AgentState {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Idle => "idle",
            Self::Done => "done",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentSource {
    Hook,
    Socket,
}

impl AgentSource {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Hook => "hook",
            Self::Socket => "socket",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentReportOptions {
    pub terminal_id: TerminalId,
    pub state: AgentState,
    pub source: AgentSource,
    pub source_session: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentListOptions {
    pub terminal_id: Option<TerminalId>,
    pub state: Option<AgentState>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SidebarEnsureOptions {
    pub size: Size,
    pub relaunch: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SidebarInputOptions {
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EventStreamOptions {
    pub cursor: Option<Cursor>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JournalStart {
    Tail,
    Beginning,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JournalSubjectFilter {
    pub kind: Option<String>,
    pub id: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum JournalRegexField {
    Kind,
    Subjects,
    Payload,
    TerminalOutput,
    #[default]
    Record,
}

impl JournalRegexField {
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Kind => "kind",
            Self::Subjects => "subjects",
            Self::Payload => "payload",
            Self::TerminalOutput => "terminal_output",
            Self::Record => "record",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JournalRegexFilter {
    pub pattern: String,
    pub field: JournalRegexField,
    pub case_sensitive: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionJournalOptions {
    pub cursor: Option<Cursor>,
    pub start: Option<JournalStart>,
    pub follow: Option<bool>,
    pub kinds: Vec<String>,
    pub classes: Vec<JournalClass>,
    pub subjects: Vec<JournalSubjectFilter>,
    pub max_sensitivity: Option<JournalSensitivity>,
    pub regex: Option<JournalRegexFilter>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionOpenOptions {
    pub session: Selector<SessionId>,
}

impl Default for SessionOpenOptions {
    fn default() -> Self {
        Self { session: Selector::current() }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShutdownOptions {
    pub force: Option<bool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RendererGrantOptions {
    pub ttl_ms: Option<u32>,
}

fn encode_hex(bytes: [u8; 16]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(32);
    for byte in bytes {
        output.push(char::from(HEX[(byte >> 4) as usize]));
        output.push(char::from(HEX[(byte & 0x0f) as usize]));
    }
    output
}

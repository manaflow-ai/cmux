//! Durable state used by agent hook callbacks.
//!
//! This module deliberately owns only persistence and lifecycle correlation.  UI
//! and socket dispatch stay in the app.  The file formats mirror the Swift CLI
//! stores (`claude-hook-sessions.json` and `codex-turn-ledger.json`), including
//! camelCase keys, bounded records, lock files, and atomic replacement.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub type HookResult<T> = std::result::Result<T, HookStateError>;

#[derive(Debug)]
pub enum HookStateError {
    Io(io::Error),
    Json(serde_json::Error),
    Lock(String),
    Invalid(String),
}
impl fmt::Display for HookStateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "hook state I/O error: {e}"),
            Self::Json(e) => write!(f, "hook state JSON error: {e}"),
            Self::Lock(e) => write!(f, "hook state lock error: {e}"),
            Self::Invalid(e) => write!(f, "invalid hook state: {e}"),
        }
    }
}
impl std::error::Error for HookStateError {}
impl From<io::Error> for HookStateError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<serde_json::Error> for HookStateError {
    fn from(e: serde_json::Error) -> Self {
        Self::Json(e)
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn normalize(s: Option<&str>) -> Option<String> {
    let s = s?.trim();
    (!s.is_empty()).then(|| s.to_string())
}
fn expand_path(path: &str) -> PathBuf {
    if path == "~" {
        return dirs_home().unwrap_or_else(|| PathBuf::from(path));
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return dirs_home().unwrap_or_else(|| PathBuf::from("~")).join(rest);
    }
    PathBuf::from(path)
}
fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn lock_exclusive(file: &File) -> HookResult<()> {
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
    if rc == 0 {
        Ok(())
    } else {
        Err(HookStateError::Lock(io::Error::last_os_error().to_string()))
    }
}
fn unlock(file: &File) {
    unsafe {
        libc::flock(file.as_raw_fd(), libc::LOCK_UN);
    }
}

fn atomic_write(path: &Path, bytes: &[u8]) -> HookResult<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|s| s.to_str()).unwrap_or("state"),
        Uuid::new_v4()
    ));
    {
        use std::io::Write;
        let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
    }
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        e
    })?;
    Ok(())
}

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

/// A JSON-preserving Claude hook record. Known routing fields are typed while
/// unknown fields are retained across a Rust write, allowing old/new app builds
/// to share the store without data loss.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeHookSessionRecord {
    pub session_id: String,
    pub workspace_id: String,
    pub surface_id: String,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub pid_start_seconds: Option<i64>,
    #[serde(default)]
    pub pid_start_microseconds: Option<i64>,
    #[serde(default)]
    pub prior_process_generations: Option<Vec<Value>>,
    #[serde(default)]
    pub launch_command: Option<Value>,
    #[serde(default)]
    pub last_permission_mode: Option<String>,
    #[serde(default)]
    pub is_restorable: Option<bool>,
    #[serde(default)]
    pub agent_lifecycle: Option<String>,
    #[serde(default)]
    pub hook_event_name: Option<String>,
    #[serde(default)]
    pub last_subtitle: Option<String>,
    #[serde(default)]
    pub last_body: Option<String>,
    #[serde(default)]
    pub last_notification_status: Option<String>,
    #[serde(default)]
    pub last_emitted_notification_fingerprint: Option<String>,
    #[serde(default)]
    pub last_emitted_notification_at: Option<f64>,
    #[serde(default)]
    pub recent_emitted_notification_fingerprints: Option<HashMap<String, f64>>,
    #[serde(default)]
    pub runtime_status: Option<String>,
    #[serde(default)]
    pub active_prompt_depth: Option<i64>,
    #[serde(default)]
    pub active_prompt_turn_id: Option<String>,
    #[serde(default)]
    pub active_prompt_turn_ids: Option<Vec<String>>,
    #[serde(default)]
    pub last_prompt_turn_id: Option<String>,
    #[serde(default)]
    pub terminal_prompt_turn_ids: Option<Vec<String>>,
    #[serde(default)]
    pub started_at: f64,
    #[serde(default)]
    pub updated_at: f64,
    #[serde(default)]
    pub superseded_cleanup_enqueued_at: Option<f64>,
    #[serde(default)]
    pub superseded_cleanup_last_attempt_at: Option<f64>,
    #[serde(default)]
    pub superseded_cleanup_attempt_count: Option<i64>,
    #[serde(default)]
    pub auto_name_last_title: Option<String>,
    #[serde(default)]
    pub auto_name_last_line_count: Option<i64>,
    #[serde(default)]
    pub auto_name_last_named_at: Option<f64>,
    #[serde(default)]
    pub auto_name_in_flight_at: Option<f64>,
    #[serde(default)]
    pub auto_name_last_attempt_at: Option<f64>,
    #[serde(default)]
    pub auto_name_recent_messages: Option<Vec<Value>>,
    #[serde(default)]
    pub auto_name_message_sequence: Option<i64>,
    #[serde(default)]
    pub had_pending_background_work_at_stop: Option<bool>,
    #[serde(default)]
    pub pending_cursor_shell_approvals: Option<Vec<PendingCursorShellApproval>>,
    #[serde(default)]
    pub recently_cleared_cursor_shell_command_fingerprints: Option<HashMap<String, f64>>,
    #[serde(default)]
    pub cursor_shell_command_only_correlation_disabled: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingCursorShellApproval {
    pub command_fingerprint: String,
    pub command_length: usize,
    pub display_command: String,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub notification_correlation_key: Option<String>,
    pub created_at: f64,
    #[serde(default)]
    pub requires_tool_use_id: bool,
}
impl PendingCursorShellApproval {
    pub fn from_command(
        command: &str,
        tool_use_id: Option<String>,
        created_at: f64,
        requires_tool_use_id: bool,
    ) -> Self {
        let normalized = command
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .trim()
            .to_string();
        let digest = sha2::Sha256::digest(normalized.as_bytes());
        let fingerprint = digest.iter().map(|b| format!("{b:02x}")).collect();
        Self {
            command_fingerprint: fingerprint,
            command_length: normalized.len(),
            display_command: "Approval needed".into(),
            tool_use_id,
            notification_correlation_key: Some(Uuid::new_v4().to_string()),
            created_at,
            requires_tool_use_id,
        }
    }
}
use sha2::Digest;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeHookActiveSessionRecord {
    pub session_id: String,
    #[serde(default)]
    pub turn_id: Option<String>,
    #[serde(default)]
    pub allows_new_session_replacement: Option<bool>,
    pub updated_at: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeHookState {
    #[serde(default)]
    pub version: i64,
    #[serde(default)]
    pub sessions: HashMap<String, ClaudeHookSessionRecord>,
    #[serde(default)]
    pub pending_superseded_session_cleanup: HashMap<String, ClaudeHookSessionRecord>,
    #[serde(default)]
    pub active_sessions_by_workspace: HashMap<String, ClaudeHookActiveSessionRecord>,
    #[serde(default)]
    pub active_sessions_by_surface: HashMap<String, ClaudeHookActiveSessionRecord>,
    #[serde(default)]
    pub agent_hook_failure_report_timestamps: HashMap<String, f64>,
    #[serde(default)]
    pub pending_cursor_approval_sessions_by_surface: HashMap<String, Vec<String>>,
    #[serde(default)]
    pub pending_cursor_approval_session_counts_by_surface: HashMap<String, i64>,
    #[serde(default)]
    pub pending_cursor_approval_surface_overflow: HashMap<String, bool>,
    #[serde(default)]
    pub pending_cursor_approval_index_initialized: bool,
}
impl ClaudeHookState {
    fn prune(&mut self) {
        let cutoff = now() - 7.0 * 24.0 * 3600.0;
        self.sessions.retain(|_, r| r.updated_at >= cutoff);
        self.pending_superseded_session_cleanup
            .retain(|_, r| r.superseded_cleanup_enqueued_at.unwrap_or(r.updated_at) >= cutoff);
        self.active_sessions_by_workspace
            .retain(|workspace, active| {
                self.sessions
                    .get(&active.session_id)
                    .map(|r| r.updated_at >= cutoff && r.workspace_id.trim() == workspace)
                    .unwrap_or(false)
            });
        self.active_sessions_by_surface.retain(|surface, active| {
            self.sessions
                .get(&active.session_id)
                .map(|r| r.surface_id.trim() == surface)
                .unwrap_or(false)
        });
        for record in self.sessions.values_mut() {
            if let Some(pending) = record.pending_cursor_shell_approvals.as_mut() {
                pending.retain(|p| now() - p.created_at <= 3600.0);
                if pending.len() > 16 {
                    pending.drain(..pending.len() - 16);
                    record.cursor_shell_command_only_correlation_disabled = Some(true);
                }
                if pending.is_empty() {
                    record.pending_cursor_shell_approvals = None;
                }
            }
            if let Some(cleared) = record
                .recently_cleared_cursor_shell_command_fingerprints
                .as_mut()
            {
                cleared.retain(|_, t| now() - *t <= 600.0);
                if cleared.len() > 16 {
                    let mut v = cleared
                        .iter()
                        .map(|(k, t)| (k.clone(), *t))
                        .collect::<Vec<_>>();
                    v.sort_by(|a, b| b.1.total_cmp(&a.1));
                    v.truncate(16);
                    *cleared = v.into_iter().collect();
                }
            }
        }
        self.reconcile_pending_index();
    }
    fn reconcile_pending_index(&mut self) {
        let mut index: HashMap<String, Vec<String>> = HashMap::new();
        let mut counts = HashMap::new();
        for (sid, r) in &self.sessions {
            if r.pending_cursor_shell_approvals
                .as_ref()
                .is_some_and(|p| !p.is_empty)
            {
                let key = r.surface_id.clone();
                *counts.entry(key.clone()).or_insert(0) += 1;
                let ids = index.entry(key).or_default();
                ids.push(sid.clone());
                if ids.len() > 256 {
                    ids.remove(0);
                }
            }
        }
        self.pending_cursor_approval_sessions_by_surface = index;
        self.pending_cursor_approval_session_counts_by_surface = counts;
        self.pending_cursor_approval_surface_overflow = self
            .pending_cursor_approval_session_counts_by_surface
            .iter()
            .filter(|(_, n)| **n > 256)
            .map(|(k, _)| (k.clone(), true))
            .collect();
        self.pending_cursor_approval_index_initialized = true;
    }
}

/// Locked, atomic Claude hook state. `mutate` is the intended integration API;
/// it gives callers one cross-process read/modify/write transaction.
pub struct ClaudeHookSessionStore {
    pub path: PathBuf,
}

/// Resolve the hook state directory with the same precedence used by the
/// native CLI. This is public so read-only commands can inspect state without
/// duplicating path rules.
pub fn state_dir(raw: Option<&str>) -> PathBuf {
    raw.and_then(|s| normalize(Some(s)))
        .map(|s| expand_path(&s))
        .unwrap_or_else(|| expand_path("~/.cmuxterm"))
}

/// Read a state file for diagnostics. Malformed JSON is returned as an error;
/// lifecycle stores themselves deliberately recover malformed files as empty
/// state, matching the Swift hook boundary.
pub fn load_store(path: &Path) -> HookResult<Value> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}
impl ClaudeHookSessionStore {
    pub fn from_env(env: &HashMap<String, String>) -> Self {
        let path = normalize(env.get("CMUX_CLAUDE_HOOK_STATE_PATH").map(String::as_str))
            .map(|p| expand_path(&p))
            .or_else(|| {
                normalize(env.get("CMUX_AGENT_HOOK_STATE_DIR").map(String::as_str))
                    .map(|p| expand_path(&p).join("claude-hook-sessions.json"))
            })
            .unwrap_or_else(|| expand_path("~/.cmuxterm/claude-hook-sessions.json"));
        Self { path }
    }
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
    fn locked(&self) -> HookResult<File> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        let lock_path = PathBuf::from(format!("{}.lock", self.path.display()));
        let f = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(lock_path)?;
        lock_exclusive(&f)?;
        Ok(f)
    }
    pub fn load(&self) -> HookResult<ClaudeHookState> {
        let bytes = match fs::read(&self.path) {
            Ok(v) => v,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                return Ok(ClaudeHookState {
                    version: 1,
                    ..Default::default()
                });
            }
            Err(e) => return Err(e.into()),
        };
        let mut state = serde_json::from_slice::<ClaudeHookState>(&bytes).unwrap_or_default();
        state.prune();
        Ok(state)
    }
    pub fn mutate<T>(
        &self,
        body: impl FnOnce(&mut ClaudeHookState) -> HookResult<T>,
    ) -> HookResult<T> {
        let lock = self.locked()?;
        let mut state = self.load()?;
        let result = body(&mut state)?;
        state.prune();
        let bytes = serde_json::to_vec_pretty(&state)?;
        atomic_write(&self.path, &bytes)?;
        unlock(&lock);
        Ok(result)
    }
    pub fn lookup(&self, session_id: &str) -> HookResult<Option<ClaudeHookSessionRecord>> {
        let id = normalize(Some(session_id));
        if id.is_none() {
            return Ok(None);
        }
        let lock = self.locked()?;
        let state = self.load()?;
        unlock(&lock);
        Ok(state.sessions.get(&id.unwrap()).cloned())
    }
    pub fn remember_cursor_shell_approval(
        &self,
        session_id: &str,
        command: &str,
        tool_use_id: Option<String>,
    ) -> HookResult<CursorApprovalRememberResult> {
        let id = normalize(Some(session_id));
        let Some(id) = id else {
            return Ok(CursorApprovalRememberResult::default());
        };
        let normalized = command
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .trim()
            .to_string();
        if normalized.is_empty() || normalized.len() > 64 * 1024 {
            return Ok(CursorApprovalRememberResult::default());
        };
        self.mutate(|state| {
            let Some(record) = state.sessions.get_mut(&id) else {
                return Ok(CursorApprovalRememberResult::default());
            };
            let now = now();
            let pending = record
                .pending_cursor_shell_approvals
                .get_or_insert_default();
            pending.retain(|p| now - p.created_at <= 3600.0);
            let fp = PendingCursorShellApproval::from_command(
                &normalized,
                tool_use_id.clone(),
                now,
                record
                    .cursor_shell_command_only_correlation_disabled
                    .unwrap_or(false),
            );
            if let Some(t) = tool_use_id {
                if let Some(existing) = pending
                    .iter()
                    .position(|p| p.tool_use_id.as_deref() == Some(t.as_str()))
                {
                    let key = pending[existing].notification_correlation_key.clone();
                    return Ok(CursorApprovalRememberResult {
                        accepted: true,
                        inserted: false,
                        notification_correlation_key: key,
                        expired_notification_correlation_keys: vec![],
                    });
                }
            }
            if pending.len() >= 16 {
                return Ok(CursorApprovalRememberResult::default());
            };
            let key = fp.notification_correlation_key.clone();
            pending.push(fp);
            record.updated_at = now;
            Ok(CursorApprovalRememberResult {
                accepted: true,
                inserted: true,
                notification_correlation_key: key,
                expired_notification_correlation_keys: vec![],
            })
        })
    }
    pub fn clear_cursor_shell_approvals(
        &self,
        session_id: &str,
    ) -> HookResult<CursorApprovalClearResult> {
        let Some(id) = normalize(Some(session_id)) else {
            return Ok(CursorApprovalClearResult::default());
        };
        self.mutate(|state| {
            let Some(r) = state.sessions.get_mut(&id) else {
                return Ok(CursorApprovalClearResult::default());
            };
            let Some(p) = r.pending_cursor_shell_approvals.take() else {
                return Ok(CursorApprovalClearResult::default());
            };
            let keys = p
                .into_iter()
                .filter_map(|x| x.notification_correlation_key)
                .collect();
            r.updated_at = now();
            Ok(CursorApprovalClearResult {
                cleared: true,
                notification_correlation_keys: keys,
            })
        })
    }
    pub fn has_pending_cursor_shell_approval(
        &self,
        surface_id: &str,
        excluding_session_id: Option<&str>,
    ) -> HookResult<bool> {
        let lock = self.locked()?;
        let s = self.load()?;
        unlock(&lock);
        Ok(s.sessions.iter().any(|(id, r)| {
            Some(id.as_str()) != excluding_session_id
                && r.surface_id == surface_id
                && r.pending_cursor_shell_approvals
                    .as_ref()
                    .is_some_and(|p| !p.is_empty)
        }))
    }
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct CursorApprovalRememberResult {
    pub accepted: bool,
    pub inserted: bool,
    pub notification_correlation_key: Option<String>,
    pub expired_notification_correlation_keys: Vec<String>,
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct CursorApprovalClearResult {
    pub cleared: bool,
    pub notification_correlation_keys: Vec<String>,
}

// ----------------------------- Codex turn ledger -----------------------------

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexProcessGeneration {
    pub pid: i64,
    pub start_seconds: i64,
    pub start_microseconds: i64,
}

#[derive(Clone, Debug, Default)]
pub struct CodexHookInvocation {
    pub token: Option<String>,
    pub parent_token: Option<String>,
    pub owner_pid: Option<i64>,
    pub observed_pid: Option<i64>,
    pub owner_generation: Option<CodexProcessGeneration>,
    pub observed_generation: Option<CodexProcessGeneration>,
    pub has_explicit_observed_pid: bool,
    pub has_nested_agent_ancestor: bool,
}
impl CodexHookInvocation {
    pub fn from_env(env: &HashMap<String, String>) -> Self {
        let clean = |k: &str| {
            normalize(env.get(k).map(String::as_str)).filter(|x| x.len() <= 128 && x.is_ascii())
        };
        let positive = |k: &str| {
            env.get(k)
                .and_then(|v| v.trim().parse::<i64>().ok())
                .filter(|p| *p > 0)
        };
        let token = clean("CMUX_CODEX_INVOCATION_ID");
        let parent_token = clean("CMUX_CODEX_PARENT_INVOCATION_ID");
        let owner_pid = positive("CMUX_CODEX_PID");
        let explicit = positive("CMUX_CODEX_HOOK_PID");
        let observed_pid = explicit.or_else(|| std::process::id().try_into().ok());
        Self {
            token,
            parent_token,
            owner_pid,
            observed_pid,
            owner_generation: None,
            observed_generation: None,
            has_explicit_observed_pid: explicit.is_some(),
            has_nested_agent_ancestor: false,
        }
    }
    pub fn with_nested_agent_ancestor(mut self, nested: bool) -> Self {
        self.has_nested_agent_ancestor = nested;
        self
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CodexTurnLedgerOwner {
    pub token: Option<String>,
    pub pid: Option<i64>,
    pub generation: Option<CodexProcessGeneration>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CodexTurnLedgerPending {
    #[serde(rename = "turnID")]
    pub turn_id: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexTurnLedgerRecord {
    pub workspace_id: String,
    pub surface_id: String,
    pub owner: CodexTurnLedgerOwner,
    pub active_turn_id: Option<String>,
    pub active_children_by_turn: HashMap<String, Vec<String>>,
    pub unknown_children_by_turn: HashMap<String, i64>,
    pub terminal_children_by_turn: HashMap<String, Vec<String>>,
    pub pending_turns: HashMap<String, CodexTurnLedgerPending>,
    pub settled_turn_ids: Vec<String>,
    pub notified_turn_ids: Vec<String>,
    pub updated_at: f64,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CodexTurnLedgerFile {
    pub records: HashMap<String, CodexTurnLedgerRecord>,
    pub surface_owners: HashMap<String, String>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CodexTurnLedgerOwnership {
    Foreground,
    Nested,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CodexTurnLedgerSettlement {
    None,
    Pending,
    Settled,
    Duplicate,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexTurnLedgerDecision {
    pub ownership: CodexTurnLedgerOwnership,
    pub settlement: CodexTurnLedgerSettlement,
    pub active_child_count: i64,
    pub turn_id: Option<String>,
    pub should_notify: bool,
}
impl CodexTurnLedgerDecision {
    pub fn ignored() -> Self {
        Self {
            ownership: CodexTurnLedgerOwnership::Unknown,
            settlement: CodexTurnLedgerSettlement::None,
            active_child_count: 0,
            turn_id: None,
            should_notify: false,
        }
    }
}

#[derive(Clone, Debug)]
enum LedgerEvent {
    SessionStart,
    PromptSubmit(Option<String>),
    SubagentStart(Option<String>, Option<String>),
    SubagentStop(Option<String>, Option<String>),
    Stop(Option<String>, bool, bool),
    SessionEnd,
    Observation,
}

pub struct CodexTurnLedger {
    pub path: PathBuf,
}
impl CodexTurnLedger {
    pub const MAXIMUM_RECORDS: usize = 256;
    const MAXIMUM_CHILDREN_PER_TURN: i64 = 128;
    const MAXIMUM_TURN_KEYS: usize = 64;
    const MAXIMUM_TERMINAL_CHILDREN_PER_TURN: usize = 256;
    const MAXIMUM_REMEMBERED_TURNS: usize = 128;
    pub fn from_env(env: &HashMap<String, String>) -> Self {
        let path = normalize(env.get("CMUX_CODEX_TURN_LEDGER_PATH").map(String::as_str))
            .map(|p| expand_path(&p))
            .or_else(|| {
                normalize(env.get("CMUX_AGENT_HOOK_STATE_DIR").map(String::as_str))
                    .map(|p| expand_path(&p).join("codex-turn-ledger.json"))
            })
            .unwrap_or_else(|| expand_path("~/.cmuxterm/codex-turn-ledger.json"));
        Self { path }
    }
    fn lock_path(&self) -> PathBuf {
        PathBuf::from(format!("{}.lock", self.path.display()))
    }
    fn locked(&self) -> HookResult<File> {
        if let Some(p) = self.path.parent() {
            fs::create_dir_all(p)?;
        }
        let f = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(self.lock_path())?;
        lock_exclusive(&f)?;
        Ok(f)
    }
    fn load_unlocked(&self) -> CodexTurnLedgerFile {
        fs::read(&self.path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    fn save_unlocked(&self, s: &CodexTurnLedgerFile) -> HookResult<()> {
        atomic_write(&self.path, &serde_json::to_vec_pretty(s)?)
    }
    pub fn is_current(&self, session_id: &str, surface_id: &str) -> HookResult<bool> {
        let sid = normalize(Some(session_id));
        let sf = normalize(Some(surface_id));
        let Some(sid) = sid else { return Ok(false) };
        let Some(sf) = sf else { return Ok(false) };
        let l = self.locked()?;
        let s = self.load_unlocked();
        unlock(&l);
        Ok(s.surface_owners.get(&sf).map(|x| x == &sid).unwrap_or(true))
    }
    fn normalize_id(s: Option<&str>) -> Option<String> {
        normalize(s).filter(|x| x.len() <= 512)
    }
    fn turn_key(id: Option<&str>) -> String {
        Self::normalize_id(id).unwrap_or_else(|| "@current".into())
    }
    pub fn session_start(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(LedgerEvent::SessionStart, s, w, sf, i, true)
    }
    pub fn prompt_submit(
        &self,
        s: &str,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
        allow_create: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(
            LedgerEvent::PromptSubmit(Self::normalize_id(t)),
            s,
            w,
            sf,
            i,
            allow_create,
        )
    }
    pub fn subagent_start(
        &self,
        s: &str,
        a: Option<&str>,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
        allow_create: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(
            LedgerEvent::SubagentStart(Self::normalize_id(a), Self::normalize_id(t)),
            s,
            w,
            sf,
            i,
            allow_create,
        )
    }
    pub fn subagent_stop(
        &self,
        s: &str,
        a: Option<&str>,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
        allow_create: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(
            LedgerEvent::SubagentStop(Self::normalize_id(a), Self::normalize_id(t)),
            s,
            w,
            sf,
            i,
            allow_create,
        )
    }
    pub fn stop(
        &self,
        s: &str,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
        claim_notification: bool,
        allow_create: bool,
        require_current_turn: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(
            LedgerEvent::Stop(
                Self::normalize_id(t),
                claim_notification,
                require_current_turn,
            ),
            s,
            w,
            sf,
            i,
            allow_create,
        )
    }
    pub fn session_end(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(LedgerEvent::SessionEnd, s, w, sf, i, true)
    }
    pub fn observe(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
        i: &CodexHookInvocation,
        allow_create: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        self.apply(LedgerEvent::Observation, s, w, sf, i, allow_create)
    }
    fn make_record(w: &str, sf: &str, i: &CodexHookInvocation) -> CodexTurnLedgerRecord {
        CodexTurnLedgerRecord {
            workspace_id: w.into(),
            surface_id: sf.into(),
            owner: CodexTurnLedgerOwner {
                token: i.token.clone(),
                pid: i.owner_pid.or(i.observed_pid),
                generation: i.owner_generation.clone().or(i.observed_generation.clone()),
            },
            active_turn_id: None,
            active_children_by_turn: HashMap::new(),
            unknown_children_by_turn: HashMap::new(),
            terminal_children_by_turn: HashMap::new(),
            pending_turns: HashMap::new(),
            settled_turn_ids: vec![],
            notified_turn_ids: vec![],
            updated_at: now(),
        }
    }
    fn same_owner(o: &CodexTurnLedgerOwner, i: &CodexHookInvocation) -> bool {
        if let (Some(a), Some(b)) = (&o.generation, &i.observed_generation) {
            return a.pid == b.pid
                && a.start_seconds == b.start_seconds
                && a.start_microseconds == b.start_microseconds;
        }
        if let (Some(a), Some(b)) = (o.pid, i.observed_pid) {
            return a == b;
        }
        if let (Some(a), Some(b)) = (&o.token, &i.token) {
            return a == b && !i.has_explicit_observed_pid;
        }
        o.pid.is_none() && i.owner_pid.is_none()
    }
    fn ownership(
        e: &LedgerEvent,
        i: &CodexHookInvocation,
        existing: Option<&CodexTurnLedgerRecord>,
        surface: Option<&CodexTurnLedgerRecord>,
    ) -> CodexTurnLedgerOwnership {
        let Some(owner) = existing.or(surface) else {
            return if i.owner_pid.is_some()
                && i.observed_pid != i.owner_pid
                && !matches!(e, LedgerEvent::SessionStart)
            {
                CodexTurnLedgerOwnership::Unknown
            } else {
                CodexTurnLedgerOwnership::Foreground
            };
        };
        if i.parent_token
            .as_deref()
            .is_some_and(|x| Some(x) == owner.owner.token.as_deref())
            || i.has_nested_agent_ancestor
        {
            return CodexTurnLedgerOwnership::Nested;
        }
        if Self::same_owner(&owner.owner, i) {
            return CodexTurnLedgerOwnership::Foreground;
        }
        if let (Some(a), Some(b)) = (&i.token, &owner.owner.token) {
            if a == b && i.has_explicit_observed_pid && owner.owner.pid != i.owner_pid {
                return CodexTurnLedgerOwnership::Nested;
            }
            if a == b {
                return CodexTurnLedgerOwnership::Foreground;
            }
        }
        if matches!(e, LedgerEvent::SessionStart) {
            return CodexTurnLedgerOwnership::Foreground;
        }
        CodexTurnLedgerOwnership::Unknown
    }
    fn child_count(r: &CodexTurnLedgerRecord) -> i64 {
        let exact: i64 = r
            .active_children_by_turn
            .values()
            .map(|v| v.len() as i64)
            .sum();
        let unknown: i64 = r.unknown_children_by_turn.values().sum();
        (exact + unknown).min(Self::MAXIMUM_CHILDREN_PER_TURN * Self::MAXIMUM_TURN_KEYS as i64)
    }
    fn child_count_for(r: &CodexTurnLedgerRecord, key: &str) -> i64 {
        ((r.active_children_by_turn
            .get(key)
            .map(|v| v.len())
            .unwrap_or(0) as i64)
            + r.unknown_children_by_turn.get(key).copied().unwrap_or(0))
        .min(Self::MAXIMUM_CHILDREN_PER_TURN)
    }
    fn decision(
        o: CodexTurnLedgerOwnership,
        s: CodexTurnLedgerSettlement,
        n: i64,
        t: Option<String>,
        notify: bool,
    ) -> CodexTurnLedgerDecision {
        CodexTurnLedgerDecision {
            ownership: o,
            settlement: s,
            active_child_count: n.max(0),
            turn_id: t,
            should_notify: notify,
        }
    }
    fn increment_unknown(r: &mut CodexTurnLedgerRecord, key: &str) {
        let n = r.unknown_children_by_turn.entry(key.into()).or_insert(0);
        *n = (*n + 1).min(Self::MAXIMUM_CHILDREN_PER_TURN);
    }
    fn start_child(r: &mut CodexTurnLedgerRecord, id: Option<String>, turn: Option<String>) {
        let key = Self::turn_key(turn.as_deref());
        if !r.active_children_by_turn.contains_key(&key)
            && !r.unknown_children_by_turn.contains_key(&key)
            && r.active_children_by_turn.len() + r.unknown_children_by_turn.len()
                >= Self::MAXIMUM_TURN_KEYS
        {
            Self::increment_unknown(r, &key);
            return;
        }
        let Some(id) = id.filter(|x| x.len() <= 512) else {
            Self::increment_unknown(r, &key);
            return;
        };
        if r.terminal_children_by_turn
            .get(&key)
            .is_some_and(|v| v.contains(&id))
        {
            return;
        }
        let children = r.active_children_by_turn.entry(key.clone()).or_default();
        if !children.contains(&id) {
            if children.len() >= Self::MAXIMUM_CHILDREN_PER_TURN as usize {
                Self::increment_unknown(r, &key)
            } else {
                children.push(id)
            }
        }
    }
    fn stop_child(r: &mut CodexTurnLedgerRecord, id: Option<String>, turn: Option<String>) {
        let key = Self::turn_key(turn.as_deref());
        let Some(id) = id else { return };
        if let Some(v) = r.active_children_by_turn.get_mut(&key) {
            v.retain(|x| x != &id);
            if v.is_empty() {
                r.active_children_by_turn.remove(&key);
            }
        }
        let v = r.terminal_children_by_turn.entry(key).or_default();
        if !v.contains(&id) {
            v.push(id)
        }
    }
    fn trim(r: &mut CodexTurnLedgerRecord) {
        let mut protected = HashSet::new();
        protected.insert(Self::turn_key(r.active_turn_id.as_deref()));
        protected.extend(r.active_children_by_turn.keys().cloned());
        protected.extend(r.unknown_children_by_turn.keys().cloned());
        protected.extend(r.pending_turns.keys().cloned());
        fn map_trim<T>(m: &mut HashMap<String, T>, limit: usize, p: &HashSet<String>) {
            if m.len() <= limit {
                return;
            }
            let mut keys: Vec<_> = m.keys().filter(|k| !p.contains(*k)).cloned().collect();
            keys.sort();
            for k in keys.into_iter().take(m.len() - limit) {
                m.remove(&k);
            }
        }
        map_trim(
            &mut r.active_children_by_turn,
            Self::MAXIMUM_TURN_KEYS,
            &protected,
        );
        map_trim(
            &mut r.unknown_children_by_turn,
            Self::MAXIMUM_TURN_KEYS,
            &protected,
        );
        map_trim(
            &mut r.terminal_children_by_turn,
            Self::MAXIMUM_TURN_KEYS,
            &protected,
        );
        map_trim(&mut r.pending_turns, Self::MAXIMUM_TURN_KEYS, &protected);
        if r.settled_turn_ids.len() > Self::MAXIMUM_REMEMBERED_TURNS {
            r.settled_turn_ids = r.settled_turn_ids
                [r.settled_turn_ids.len() - Self::MAXIMUM_REMEMBERED_TURNS..]
                .to_vec()
        }
        if r.notified_turn_ids.len() > Self::MAXIMUM_REMEMBERED_TURNS {
            r.notified_turn_ids = r.notified_turn_ids
                [r.notified_turn_ids.len() - Self::MAXIMUM_REMEMBERED_TURNS..]
                .to_vec()
        }
        for v in r.terminal_children_by_turn.values_mut() {
            if v.len() > Self::MAXIMUM_TERMINAL_CHILDREN_PER_TURN {
                *v = v[v.len() - Self::MAXIMUM_TERMINAL_CHILDREN_PER_TURN..].to_vec();
            }
        }
    }
    fn prune(s: &mut CodexTurnLedgerFile, limit: usize) {
        if s.records.len() <= limit {
            return;
        }
        let mut ids: Vec<_> = s
            .records
            .iter()
            .filter(|(_, r)| {
                r.active_children_by_turn.is_empty()
                    && r.unknown_children_by_turn.is_empty()
                    && r.pending_turns.is_empty()
            })
            .map(|(id, r)| (id.clone(), r.updated_at))
            .collect();
        ids.sort_by(|a, b| a.1.total_cmp(&b.1));
        let remove = ids
            .into_iter()
            .take(s.records.len() - limit)
            .map(|x| x.0)
            .collect::<HashSet<_>>();
        for id in &remove {
            s.records.remove(id);
        }
        s.surface_owners.retain(|_, id| s.records.contains_key(id));
    }
    fn apply(
        &self,
        event: LedgerEvent,
        session: &str,
        workspace: Option<&str>,
        surface: Option<&str>,
        inv: &CodexHookInvocation,
        allow_create: bool,
    ) -> HookResult<CodexTurnLedgerDecision> {
        let sid = Self::normalize_id(Some(session)).unwrap_or_default();
        if sid.is_empty() {
            return Ok(CodexTurnLedgerDecision::ignored());
        }
        let lock = self.locked()?;
        let mut state = self.load_unlocked();
        Self::prune(&mut state, Self::MAXIMUM_RECORDS);
        let w = Self::normalize_id(workspace).unwrap_or_default();
        let sf = Self::normalize_id(surface).unwrap_or_default();
        let existing = state.records.get(&sid).cloned();
        let owner = if sf.is_empty() {
            None
        } else {
            state
                .surface_owners
                .get(&sf)
                .and_then(|x| state.records.get(x))
                .cloned()
        };
        if !allow_create && existing.is_none() && owner.is_none() {
            unlock(&lock);
            return Ok(CodexTurnLedgerDecision::ignored());
        }
        let own = Self::ownership(&event, inv, existing.as_ref(), owner.as_ref());
        if existing.is_none() && owner.is_none() && state.records.len() >= Self::MAXIMUM_RECORDS {
            Self::prune(&mut state, Self::MAXIMUM_RECORDS - 1);
            if state.records.len() >= Self::MAXIMUM_RECORDS {
                unlock(&lock);
                return Ok(CodexTurnLedgerDecision::ignored());
            }
        }
        if matches!(event, LedgerEvent::SessionStart) && own == CodexTurnLedgerOwnership::Foreground
        {
            let same = existing
                .as_ref()
                .is_some_and(|r| Self::same_owner(&r.owner, inv));
            let mut r = existing.unwrap_or_else(|| Self::make_record(&w, &sf, inv));
            if !w.is_empty() {
                r.workspace_id = w.clone()
            }
            if !sf.is_empty() {
                r.surface_id = sf.clone()
            }
            if !same {
                r = Self::make_record(&r.workspace_id, &r.surface_id, inv);
                if let Some(old) = owner.as_ref() {
                    if let Some(old_sid) = state.surface_owners.get(&sf).cloned() {
                        if old_sid != sid && !Self::same_owner(&old.owner, inv) {
                            state.records.remove(&old_sid)
                        }
                    }
                }
            }
            state.records.insert(sid.clone(), r.clone());
            if !sf.is_empty() {
                state.surface_owners.insert(sf, sid)
            }
            let out = Self::decision(
                CodexTurnLedgerOwnership::Foreground,
                CodexTurnLedgerSettlement::None,
                Self::child_count(&r),
                r.active_turn_id.clone(),
                false,
            );
            self.save_unlocked(&state)?;
            unlock(&lock);
            return Ok(out);
        }
        if own != CodexTurnLedgerOwnership::Foreground {
            let r = existing.as_ref().or(owner.as_ref());
            let out = Self::decision(
                own,
                CodexTurnLedgerSettlement::None,
                r.map(Self::child_count).unwrap_or(0),
                existing.as_ref().and_then(|r| r.active_turn_id.clone()),
                false,
            );
            unlock(&lock);
            return Ok(out);
        }
        let mut r = existing
            .or(owner)
            .unwrap_or_else(|| Self::make_record(&w, &sf, inv));
        if !w.is_empty() {
            r.workspace_id = w
        }
        if !sf.is_empty() {
            r.surface_id = sf
        }
        let out = match event {
            LedgerEvent::PromptSubmit(t) => {
                let key = Self::turn_key(t.as_deref());
                r.active_turn_id = t.clone();
                r.pending_turns.remove(&key);
                r.settled_turn_ids.retain(|x| x != &key);
                r.notified_turn_ids.retain(|x| x != &key);
                r.terminal_children_by_turn.remove(&key);
                Self::decision(
                    own,
                    CodexTurnLedgerSettlement::None,
                    Self::child_count(&r),
                    r.active_turn_id.clone(),
                    false,
                )
            }
            LedgerEvent::SubagentStart(a, t) => {
                Self::start_child(&mut r, a, t.clone());
                Self::decision(
                    own,
                    CodexTurnLedgerSettlement::None,
                    Self::child_count(&r),
                    t.or(r.active_turn_id.clone()),
                    false,
                )
            }
            LedgerEvent::SubagentStop(a, t) => {
                let key = Self::turn_key(t.as_deref().or(r.active_turn_id.as_deref()));
                let valid = a.is_some();
                Self::stop_child(&mut r, a, t.clone());
                if valid && Self::child_count_for(&r, &key) == 0 {
                    if let Some(p) = r.pending_turns.remove(&key) {
                        let fresh = !r.settled_turn_ids.contains(&key);
                        if fresh {
                            r.settled_turn_ids.push(key)
                        }
                        let notify = !r
                            .notified_turn_ids
                            .contains(&Self::turn_key(p.turn_id.as_deref()));
                        Self::decision(
                            own,
                            CodexTurnLedgerSettlement::Settled,
                            Self::child_count(&r),
                            p.turn_id,
                            notify,
                        )
                    } else {
                        Self::decision(
                            own,
                            CodexTurnLedgerSettlement::None,
                            Self::child_count(&r),
                            t.or(r.active_turn_id.clone()),
                            false,
                        )
                    }
                } else {
                    Self::decision(
                        own,
                        CodexTurnLedgerSettlement::None,
                        Self::child_count(&r),
                        t.or(r.active_turn_id.clone()),
                        false,
                    )
                }
            }
            LedgerEvent::Stop(t, claim, require) => {
                let key = Self::turn_key(t.as_deref().or(r.active_turn_id.as_deref()));
                if require
                    && r.active_turn_id.is_none()
                    && !r.pending_turns.contains_key(&key)
                    && !claim
                {
                    unlock(&lock);
                    return Ok(CodexTurnLedgerDecision::ignored());
                }
                if require
                    && t.is_some()
                    && r.active_turn_id.as_ref() != t.as_ref()
                    && !r.pending_turns.contains_key(&key)
                {
                    unlock(&lock);
                    return Ok(CodexTurnLedgerDecision::ignored());
                }
                let id = t.or(r.active_turn_id.clone());
                let active = Self::child_count(&r);
                if active > 0 {
                    r.pending_turns.insert(
                        key,
                        CodexTurnLedgerPending {
                            turn_id: id.clone(),
                        },
                    );
                    Self::decision(own, CodexTurnLedgerSettlement::Pending, active, id, false)
                } else if r.settled_turn_ids.contains(&key) {
                    let notify = !r.notified_turn_ids.contains(&key);
                    if claim && notify {
                        r.notified_turn_ids.push(key)
                    }
                    Self::decision(
                        own,
                        if notify {
                            CodexTurnLedgerSettlement::Settled
                        } else {
                            CodexTurnLedgerSettlement::Duplicate
                        },
                        0,
                        id,
                        notify,
                    )
                } else {
                    r.pending_turns.remove(&key);
                    r.settled_turn_ids.push(key.clone());
                    let notify = !r.notified_turn_ids.contains(&key);
                    if claim && notify {
                        r.notified_turn_ids.push(key)
                    }
                    Self::decision(own, CodexTurnLedgerSettlement::Settled, 0, id, notify)
                }
            }
            LedgerEvent::SessionEnd => {
                if !r.surface_id.is_empty() && state.surface_owners.get(&r.surface_id) == Some(&sid)
                {
                    state.surface_owners.remove(&r.surface_id)
                }
                state.records.remove(&sid);
                self.save_unlocked(&state)?;
                unlock(&lock);
                return Ok(Self::decision(
                    own,
                    CodexTurnLedgerSettlement::None,
                    0,
                    None,
                    false,
                ));
            }
            LedgerEvent::Observation | LedgerEvent::SessionStart => Self::decision(
                own,
                CodexTurnLedgerSettlement::None,
                Self::child_count(&r),
                r.active_turn_id.clone(),
                false,
            ),
        };
        r.updated_at = now();
        Self::trim(&mut r);
        state.records.insert(sid.clone(), r.clone());
        if !r.surface_id.is_empty() {
            state.surface_owners.insert(r.surface_id.clone(), sid)
        }
        Self::prune(&mut state, Self::MAXIMUM_RECORDS);
        self.save_unlocked(&state)?;
        unlock(&lock);
        Ok(out)
    }
}

/// Thin lifecycle facade used by hook dispatchers. It mirrors the Swift
/// coordinator: persistence failures are fail-closed as an ignored decision.
pub struct CodexTurnLifecycleCoordinator {
    pub ledger: CodexTurnLedger,
    pub invocation: CodexHookInvocation,
}
impl CodexTurnLifecycleCoordinator {
    pub fn new(env: &HashMap<String, String>) -> Self {
        let invocation = CodexHookInvocation::from_env(env);
        Self {
            ledger: CodexTurnLedger::from_env(env),
            invocation,
        }
    }
    pub fn uses_legacy_identity(&self) -> bool {
        self.invocation.token.is_none() && self.invocation.owner_pid.is_none()
    }
    pub fn session_start(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
    ) -> CodexTurnLedgerDecision {
        self.ledger
            .session_start(s, w, sf, &self.invocation)
            .unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn prompt_submit(
        &self,
        s: &str,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        allow: bool,
    ) -> CodexTurnLedgerDecision {
        self.ledger
            .prompt_submit(s, t, w, sf, &self.invocation, allow)
            .unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn subagent(
        &self,
        s: &str,
        a: Option<&str>,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        starts: bool,
        allow: bool,
    ) -> CodexTurnLedgerDecision {
        let r = if starts {
            self.ledger
                .subagent_start(s, a, t, w, sf, &self.invocation, allow)
        } else {
            self.ledger
                .subagent_stop(s, a, t, w, sf, &self.invocation, allow)
        };
        r.unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn stop(
        &self,
        s: &str,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        claim: bool,
        allow: bool,
        require: bool,
    ) -> CodexTurnLedgerDecision {
        self.ledger
            .stop(s, t, w, sf, &self.invocation, claim, allow, require)
            .unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn observe(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
        allow: bool,
    ) -> CodexTurnLedgerDecision {
        self.ledger
            .observe(s, w, sf, &self.invocation, allow)
            .unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn session_end(
        &self,
        s: &str,
        w: Option<&str>,
        sf: Option<&str>,
    ) -> CodexTurnLedgerDecision {
        self.ledger
            .session_end(s, w, sf, &self.invocation)
            .unwrap_or_else(|_| CodexTurnLedgerDecision::ignored())
    }
    pub fn record_feed_lifecycle(
        &self,
        s: &str,
        event: &str,
        a: Option<&str>,
        t: Option<&str>,
        w: Option<&str>,
        sf: Option<&str>,
        allow: bool,
    ) -> CodexTurnLedgerDecision {
        match event {
            "SubagentStart" => self.subagent(s, a, t, w, sf, true, allow),
            "SubagentStop" => self.subagent(s, a, t, w, sf, false, allow),
            _ => CodexTurnLedgerDecision::ignored(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CodexMonitorOwnerState {
    Alive,
    Gone,
    Unknown,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexTranscriptFailureReadResult<T = Value> {
    Unavailable,
    Pending,
    Healthy(Option<String>),
    Failure(T),
}

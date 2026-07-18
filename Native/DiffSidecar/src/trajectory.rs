use std::collections::HashMap;
use std::ffi::OsString;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Deserialize;
use serde_json::Value;

use crate::protocol::AgentProvider;

const MAX_SESSION_ID_BYTES: usize = 512;
const MAX_JSONL_LINE_BYTES: usize = 16 * 1024 * 1024;
const MAX_HOOK_STORE_BYTES: usize = 16 * 1024 * 1024;
const MAX_TRANSCRIPT_BYTES: u64 = 512 * 1024 * 1024;
const MAX_PATCH_BYTES: usize = 64 * 1024 * 1024;
const MAX_CLAUDE_SUBAGENT_TRANSCRIPTS: usize = 128;
const MAX_CLAUDE_PROJECT_DIRECTORIES: usize = 4096;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct AgentTurnIdentity {
    pub provider: AgentProvider,
    pub session_id: String,
}

#[derive(Clone, Debug, Default)]
pub struct TrajectoryCancellation(Arc<AtomicBool>);

impl TrajectoryCancellation {
    /// Requests cooperative cancellation of the active trajectory scan.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    fn check(&self) -> Result<(), TrajectoryError> {
        if self.0.load(Ordering::Acquire) {
            Err(TrajectoryError::Unavailable)
        } else {
            Ok(())
        }
    }
}

impl AgentTurnIdentity {
    #[must_use]
    pub fn new(provider: AgentProvider, session_id: impl Into<String>) -> Self {
        Self {
            provider,
            session_id: session_id.into(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TrajectoryRoots {
    home: PathBuf,
    hook_state_dir: Option<PathBuf>,
    claude_hook_state_path: Option<PathBuf>,
}

impl TrajectoryRoots {
    #[must_use]
    pub fn for_home(home: PathBuf) -> Self {
        Self {
            home,
            hook_state_dir: None,
            claude_hook_state_path: None,
        }
    }

    /// Resolves trajectory storage from the current process environment.
    ///
    /// # Errors
    ///
    /// Returns [`TrajectoryError::Unavailable`] when `HOME` is unset or empty.
    pub fn from_environment() -> Result<Self, TrajectoryError> {
        Self::from_environment_values(|key| std::env::var_os(key))
    }

    fn from_environment_values(
        mut value: impl FnMut(&str) -> Option<OsString>,
    ) -> Result<Self, TrajectoryError> {
        let home = value("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or(TrajectoryError::Unavailable)?;
        let hook_state_dir = value("CMUX_AGENT_HOOK_STATE_DIR")
            .filter(|value| !value.is_empty())
            .map(|path| expand_home(Path::new(&path), &home));
        let claude_hook_state_path = value("CMUX_CLAUDE_HOOK_STATE_PATH")
            .filter(|value| !value.is_empty())
            .map(|path| expand_home(Path::new(&path), &home));
        Ok(Self {
            home,
            hook_state_dir,
            claude_hook_state_path,
        })
    }

    fn hook_store(&self, provider: AgentProvider) -> PathBuf {
        let name = match provider {
            AgentProvider::Codex => "codex",
            AgentProvider::Claude => "claude",
            AgentProvider::OpenCode => "opencode",
        };
        if provider == AgentProvider::Claude
            && let Some(path) = &self.claude_hook_state_path
        {
            return path.clone();
        }
        self.hook_state_dir
            .clone()
            .unwrap_or_else(|| self.home.join(".cmuxterm"))
            .join(format!("{name}-hook-sessions.json"))
    }

    fn codex_database(&self) -> PathBuf {
        self.home.join(".codex/state_5.sqlite")
    }

    fn claude_projects(&self) -> PathBuf {
        self.home.join(".claude/projects")
    }

    fn opencode_database(&self) -> PathBuf {
        self.home.join(".local/share/opencode/opencode.db")
    }
}

fn expand_home(path: &Path, home: &Path) -> PathBuf {
    if path == Path::new("~") {
        return home.to_path_buf();
    }
    path.strip_prefix(Path::new("~/"))
        .map_or_else(|_| path.to_path_buf(), |suffix| home.join(suffix))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedTurnPatch {
    pub repo_root: PathBuf,
    pub patch: String,
}

#[derive(Clone, Debug)]
pub struct AgentTurnLocation {
    repo_root: PathBuf,
    transcript: Option<PathBuf>,
    generation: AgentTurnGeneration,
}

impl AgentTurnLocation {
    #[must_use]
    pub fn repo_root(&self) -> &Path {
        &self.repo_root
    }

    pub(crate) fn generation(&self) -> &AgentTurnGeneration {
        &self.generation
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) enum AgentTurnGeneration {
    Transcript(Vec<TranscriptGeneration>),
    OpenCode {
        database: PathBuf,
        latest_user_message: Option<String>,
        patch_part_count: i64,
        latest_patch_part: Option<String>,
    },
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct TranscriptGeneration {
    path: PathBuf,
    byte_length: u64,
    modified: Option<SystemTime>,
}

#[cfg(test)]
impl AgentTurnGeneration {
    pub(crate) fn for_test(discriminator: u64) -> Self {
        Self::Transcript(vec![TranscriptGeneration {
            path: PathBuf::from(format!("test-{discriminator}")),
            byte_length: discriminator,
            modified: None,
        }])
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrajectoryError {
    Unavailable,
    Invalid,
    Empty,
}

impl std::fmt::Display for TrajectoryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self {
            Self::Unavailable => "agent trajectory is unavailable",
            Self::Invalid => "agent trajectory is invalid",
            Self::Empty => "agent turn has no recorded patches",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for TrajectoryError {}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HookStore {
    #[serde(default)]
    sessions: HashMap<String, HookRecord>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HookRecord {
    cwd: Option<String>,
    transcript_path: Option<String>,
    launch_command: Option<HookLaunchCommand>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HookLaunchCommand {
    #[serde(default)]
    environment: HashMap<String, String>,
}

/// Resolves the patch recorded for an agent session's latest turn.
///
/// # Errors
///
/// Returns an error when the identity is invalid, trajectory storage is
/// unavailable or malformed, or the latest turn has no patch events.
pub fn resolve_last_turn_patch(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
    resolve_last_turn_patch_cancellable(identity, roots, &TrajectoryCancellation::default())
}

/// Resolves the last recorded turn while observing cooperative cancellation.
///
/// # Errors
///
/// Returns [`TrajectoryError`] when the trajectory is unavailable, invalid,
/// empty, or cancelled.
pub fn resolve_last_turn_patch_cancellable(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
    cancellation: &TrajectoryCancellation,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
    let location = resolve_agent_turn_location_cancellable(identity, roots, cancellation)?;
    resolve_last_turn_patch_at_location_cancellable(identity, roots, &location, cancellation)
}

/// Resolves a turn from provider metadata that was already located and authorized.
///
/// # Errors
///
/// Returns [`TrajectoryError`] when the stored location is incomplete or the
/// trajectory is unavailable, invalid, empty, or cancelled.
pub fn resolve_last_turn_patch_at_location_cancellable(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
    location: &AgentTurnLocation,
    cancellation: &TrajectoryCancellation,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
    cancellation.check()?;
    validate_session_id(&identity.session_id)?;
    match identity.provider {
        AgentProvider::Codex => {
            let transcript = location
                .transcript
                .as_deref()
                .ok_or(TrajectoryError::Unavailable)?;
            let patch = codex_last_turn_patch(transcript, &location.repo_root, cancellation)?;
            finish(location.repo_root.clone(), patch)
        }
        AgentProvider::Claude => {
            let transcript = location
                .transcript
                .as_deref()
                .ok_or(TrajectoryError::Unavailable)?;
            let patch = claude_last_turn_patch(transcript, &location.repo_root, cancellation)?;
            finish(location.repo_root.clone(), patch)
        }
        AgentProvider::OpenCode => resolve_opencode(identity, roots, cancellation),
    }
}

/// Resolves only the canonical repository associated with an agent session.
///
/// Callers can authorize this path before scanning the potentially large
/// trajectory that contains the turn's patches.
///
/// # Errors
///
/// Returns [`TrajectoryError`] when the identity or provider metadata is invalid
/// or unavailable.
pub fn resolve_agent_turn_repository(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<PathBuf, TrajectoryError> {
    let cancellation = TrajectoryCancellation::default();
    resolve_agent_turn_location_cancellable(identity, roots, &cancellation)
        .map(|location| location.repo_root)
}

/// Locates the canonical repository and provider transcript for an agent turn.
///
/// # Errors
///
/// Returns [`TrajectoryError`] when the identity or provider metadata is invalid,
/// unavailable, or cancelled.
pub fn resolve_agent_turn_location_cancellable(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
    cancellation: &TrajectoryCancellation,
) -> Result<AgentTurnLocation, TrajectoryError> {
    cancellation.check()?;
    validate_session_id(&identity.session_id)?;
    match identity.provider {
        AgentProvider::Codex => {
            codex_location(identity, roots).and_then(|(transcript, repo_root)| {
                let generation =
                    AgentTurnGeneration::Transcript(vec![transcript_generation(&transcript)?]);
                Ok(AgentTurnLocation {
                    repo_root,
                    transcript: Some(transcript),
                    generation,
                })
            })
        }
        AgentProvider::Claude => {
            claude_location(identity, roots, cancellation).and_then(|(transcript, repo_root)| {
                let generation = claude_transcript_generation(&transcript, cancellation)?;
                Ok(AgentTurnLocation {
                    repo_root,
                    transcript: Some(transcript),
                    generation,
                })
            })
        }
        AgentProvider::OpenCode => {
            opencode_location(identity, roots).map(|(repo_root, generation)| AgentTurnLocation {
                repo_root,
                transcript: None,
                generation,
            })
        }
    }
}

fn transcript_generation(path: &Path) -> Result<TranscriptGeneration, TrajectoryError> {
    let metadata = path.metadata().map_err(|_| TrajectoryError::Unavailable)?;
    if !metadata.is_file() {
        return Err(TrajectoryError::Unavailable);
    }
    Ok(TranscriptGeneration {
        path: path.to_path_buf(),
        byte_length: metadata.len(),
        modified: metadata.modified().ok(),
    })
}

fn claude_transcript_generation(
    transcript: &Path,
    cancellation: &TrajectoryCancellation,
) -> Result<AgentTurnGeneration, TrajectoryError> {
    let mut generations = vec![transcript_generation(transcript)?];
    let subagent_directory = transcript.with_extension("").join("subagents");
    let entries = match std::fs::read_dir(subagent_directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AgentTurnGeneration::Transcript(generations));
        }
        Err(_) => return Err(TrajectoryError::Unavailable),
    };
    let mut paths = Vec::new();
    for entry in entries {
        cancellation.check()?;
        let path = entry.map_err(|_| TrajectoryError::Invalid)?.path();
        let is_subagent_transcript = path.extension().and_then(|value| value.to_str())
            == Some("jsonl")
            && path
                .file_stem()
                .and_then(|value| value.to_str())
                .is_some_and(|name| name.starts_with("agent-") && name.len() > "agent-".len());
        if is_subagent_transcript {
            paths.push(path);
            if paths.len() > MAX_CLAUDE_SUBAGENT_TRANSCRIPTS {
                return Err(TrajectoryError::Invalid);
            }
        }
    }
    paths.sort_unstable();
    for path in paths {
        generations.push(transcript_generation(&path)?);
    }
    Ok(AgentTurnGeneration::Transcript(generations))
}

fn validate_session_id(session_id: &str) -> Result<(), TrajectoryError> {
    if session_id.is_empty()
        || session_id.len() > MAX_SESSION_ID_BYTES
        || session_id.chars().any(char::is_control)
        || session_id.contains(['/', '\\'])
        || matches!(session_id, "." | "..")
    {
        return Err(TrajectoryError::Invalid);
    }
    Ok(())
}

fn codex_location(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<(PathBuf, PathBuf), TrajectoryError> {
    let hook = read_hook_record(roots, identity.provider, &identity.session_id);
    let (transcript, repo_root) = if let Some(record) = hook
        .as_ref()
        .filter(|record| record.transcript_path.is_some() && record.cwd.is_some())
    {
        (
            expanded_path(
                record
                    .transcript_path
                    .as_deref()
                    .ok_or(TrajectoryError::Unavailable)?,
            ),
            expanded_path(record.cwd.as_deref().ok_or(TrajectoryError::Unavailable)?),
        )
    } else {
        let database = hook
            .as_ref()
            .and_then(|record| record.launch_command.as_ref())
            .and_then(|command| command.environment.get("CODEX_HOME"))
            .filter(|path| !path.trim().is_empty())
            .map_or_else(
                || roots.codex_database(),
                |path| expand_home(Path::new(path), &roots.home).join("state_5.sqlite"),
            );
        let (transcript, repo_root) = read_codex_database_record(&database, &identity.session_id)
            .ok_or(TrajectoryError::Unavailable)?;
        (
            expanded_path(&transcript),
            expanded_path(repo_root.as_deref().ok_or(TrajectoryError::Unavailable)?),
        )
    };
    let repo_root = canonical_repository_root(&repo_root)?;
    Ok((transcript, repo_root))
}

fn claude_location(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
    cancellation: &TrajectoryCancellation,
) -> Result<(PathBuf, PathBuf), TrajectoryError> {
    let hook = read_hook_record(roots, identity.provider, &identity.session_id);
    let (transcript, repo_root) = if let Some(record) =
        hook.filter(|record| record.transcript_path.is_some() && record.cwd.is_some())
    {
        (
            expanded_path(
                record
                    .transcript_path
                    .as_deref()
                    .ok_or(TrajectoryError::Unavailable)?,
            ),
            expanded_path(record.cwd.as_deref().ok_or(TrajectoryError::Unavailable)?),
        )
    } else {
        let transcript = find_claude_transcript(roots, &identity.session_id, cancellation)
            .ok_or(TrajectoryError::Unavailable)?;
        let repo_root =
            claude_transcript_cwd(&transcript, cancellation).ok_or(TrajectoryError::Unavailable)?;
        (transcript, repo_root)
    };
    let repo_root = canonical_repository_root(&repo_root)?;
    Ok((transcript, repo_root))
}

fn resolve_opencode(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
    cancellation: &TrajectoryCancellation,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
    cancellation.check()?;
    let connection = open_opencode_database(&roots.opencode_database())?;
    let repo_root = opencode_repository_from_connection(identity, &connection)?;
    cancellation.check()?;
    let user_message: String = connection
        .query_row(
            "SELECT id FROM message \
             WHERE session_id = ?1 AND json_extract(data, '$.role') = 'user' \
             ORDER BY time_created DESC, id DESC LIMIT 1",
            [&identity.session_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| TrajectoryError::Invalid)?
        .ok_or(TrajectoryError::Empty)?;
    let mut statement = connection
        .prepare(
            "SELECT json_extract(part.data, '$.state.metadata.diff') \
             FROM part JOIN message ON message.id = part.message_id \
             WHERE message.session_id = ?1 \
               AND json_extract(message.data, '$.role') = 'assistant' \
               AND json_extract(message.data, '$.parentID') = ?2 \
               AND json_type(part.data, '$.state.metadata.diff') = 'text' \
             ORDER BY part.time_created, part.id",
        )
        .map_err(|_| TrajectoryError::Invalid)?;
    let rows = statement
        .query_map(params![identity.session_id, user_message], |row| {
            row.get::<_, String>(0)
        })
        .map_err(|_| TrajectoryError::Invalid)?;
    let mut patch = String::new();
    for row in rows {
        cancellation.check()?;
        append_opencode_patch(
            &mut patch,
            &repo_root,
            &row.map_err(|_| TrajectoryError::Invalid)?,
        )?;
    }
    finish(repo_root, patch)
}

fn opencode_location(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<(PathBuf, AgentTurnGeneration), TrajectoryError> {
    let database = roots.opencode_database();
    let connection = open_opencode_database(&database)?;
    let repo_root = opencode_repository_from_connection(identity, &connection)?;
    let latest_user_message = connection
        .query_row(
            "SELECT id FROM message \
             WHERE session_id = ?1 AND json_extract(data, '$.role') = 'user' \
             ORDER BY time_created DESC, id DESC LIMIT 1",
            [&identity.session_id],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|_| TrajectoryError::Invalid)?;
    let (patch_part_count, latest_patch_part) = if let Some(user_message) = &latest_user_message {
        connection
            .query_row(
                "SELECT COUNT(*), MAX(part.id) \
                 FROM part JOIN message ON message.id = part.message_id \
                 WHERE message.session_id = ?1 \
                   AND json_extract(message.data, '$.role') = 'assistant' \
                   AND json_extract(message.data, '$.parentID') = ?2 \
                   AND json_type(part.data, '$.state.metadata.diff') = 'text'",
                params![identity.session_id, user_message],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .map_err(|_| TrajectoryError::Invalid)?
    } else {
        (0, None)
    };
    Ok((
        repo_root,
        AgentTurnGeneration::OpenCode {
            database,
            latest_user_message,
            patch_part_count,
            latest_patch_part,
        },
    ))
}

fn open_opencode_database(path: &Path) -> Result<Connection, TrajectoryError> {
    let connection = open_read_only_database(path)?;
    connection
        .set_limit(
            rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH,
            i32::try_from(MAX_PATCH_BYTES).map_err(|_| TrajectoryError::Invalid)?,
        )
        .map_err(|_| TrajectoryError::Invalid)?;
    Ok(connection)
}

fn opencode_repository_from_connection(
    identity: &AgentTurnIdentity,
    connection: &Connection,
) -> Result<PathBuf, TrajectoryError> {
    let repo: String = connection
        .query_row(
            "SELECT directory FROM session WHERE id = ?1 LIMIT 1",
            [&identity.session_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| TrajectoryError::Invalid)?
        .ok_or(TrajectoryError::Unavailable)?;
    canonical_repository_root(&expanded_path(&repo))
}

fn finish(repo_root: PathBuf, patch: String) -> Result<ResolvedTurnPatch, TrajectoryError> {
    if patch.trim().is_empty() {
        return Err(TrajectoryError::Empty);
    }
    if patch.len() > MAX_PATCH_BYTES {
        return Err(TrajectoryError::Invalid);
    }
    Ok(ResolvedTurnPatch { repo_root, patch })
}

fn read_hook_record(
    roots: &TrajectoryRoots,
    provider: AgentProvider,
    session_id: &str,
) -> Option<HookRecord> {
    let bytes = read_file_capped(&roots.hook_store(provider), MAX_HOOK_STORE_BYTES)?;
    serde_json::from_slice::<HookStore>(&bytes)
        .ok()?
        .sessions
        .get(session_id)
        .cloned()
}

fn read_file_capped(path: &Path, maximum_bytes: usize) -> Option<Vec<u8>> {
    let file = File::open(path).ok()?;
    let byte_length = file.metadata().ok()?.len();
    if byte_length > u64::try_from(maximum_bytes).ok()? {
        return None;
    }
    let capacity = usize::try_from(byte_length).ok()?;
    let mut bytes = Vec::with_capacity(capacity);
    file.take(u64::try_from(maximum_bytes).ok()?.saturating_add(1))
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= maximum_bytes).then_some(bytes)
}

fn read_codex_database_record(
    database: &Path,
    session_id: &str,
) -> Option<(String, Option<String>)> {
    let connection = open_read_only_database(database).ok()?;
    connection
        .query_row(
            "SELECT rollout_path, cwd FROM threads WHERE id = ?1 LIMIT 1",
            [session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .ok()?
}

fn open_read_only_database(path: &Path) -> Result<Connection, TrajectoryError> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| TrajectoryError::Unavailable)?;
    connection
        .busy_timeout(Duration::from_millis(250))
        .map_err(|_| TrajectoryError::Invalid)?;
    Ok(connection)
}

fn find_claude_transcript(
    roots: &TrajectoryRoots,
    session_id: &str,
    cancellation: &TrajectoryCancellation,
) -> Option<PathBuf> {
    find_claude_transcript_with_limit(
        &roots.claude_projects(),
        session_id,
        cancellation,
        MAX_CLAUDE_PROJECT_DIRECTORIES,
    )
}

fn find_claude_transcript_with_limit(
    projects: &Path,
    session_id: &str,
    cancellation: &TrajectoryCancellation,
    directory_limit: usize,
) -> Option<PathBuf> {
    let filename = format!("{session_id}.jsonl");
    let mut found = None;
    for (index, entry) in std::fs::read_dir(projects).ok()?.enumerate() {
        cancellation.check().ok()?;
        if index >= directory_limit {
            return None;
        }
        let entry = entry.ok()?;
        let candidate = entry.path().join(&filename);
        if candidate.is_file() {
            found = Some(candidate);
        }
    }
    found
}

fn claude_transcript_cwd(
    transcript: &Path,
    cancellation: &TrajectoryCancellation,
) -> Option<PathBuf> {
    let mut cwd = None;
    for_json_lines(transcript, cancellation, |object| {
        cwd = object.get("cwd").and_then(Value::as_str).map(expanded_path);
        Ok(cwd.is_some())
    })
    .ok()?;
    cwd
}

fn codex_last_turn_patch(
    transcript: &Path,
    repo_root: &Path,
    cancellation: &TrajectoryCancellation,
) -> Result<String, TrajectoryError> {
    let mut current_turn = None::<String>;
    let mut patch = String::new();
    for_json_lines(transcript, cancellation, |object| {
        let Some(payload) = object.get("payload") else {
            return Ok(false);
        };
        let object_type = object.get("type").and_then(Value::as_str);
        let turn_id = codex_turn_id(payload);
        if object_type == Some("turn_context") {
            if let Some(turn_id) = turn_id
                && current_turn.as_deref() != Some(turn_id)
            {
                current_turn = Some(turn_id.to_owned());
                patch.clear();
            } else if turn_id.is_none() {
                current_turn = None;
                patch.clear();
            }
            return Ok(false);
        }
        if object_type != Some("event_msg") {
            return Ok(false);
        }
        let event_type = payload.get("type").and_then(Value::as_str);
        if event_type == Some("task_started") {
            let Some(turn_id) = turn_id else {
                current_turn = None;
                patch.clear();
                return Err(TrajectoryError::Invalid);
            };
            current_turn = Some(turn_id.to_owned());
            patch.clear();
            return Ok(false);
        }
        if event_type != Some("patch_apply_end")
            || payload.get("success") != Some(&Value::Bool(true))
        {
            return Ok(false);
        }
        if let Some(turn_id) = turn_id {
            if current_turn.as_deref() != Some(turn_id) {
                current_turn = Some(turn_id.to_owned());
                patch.clear();
            }
        } else if current_turn.is_none() {
            return Err(TrajectoryError::Invalid);
        }
        if let Some(changes) = payload.get("changes").and_then(Value::as_object) {
            for (path, change) in changes {
                append_codex_change(&mut patch, repo_root, path, change)?;
            }
        }
        Ok(false)
    })?;
    Ok(patch)
}

fn codex_turn_id(payload: &Value) -> Option<&str> {
    payload
        .get("turn_id")
        .or_else(|| payload.get("turnId"))
        .and_then(Value::as_str)
}

fn append_codex_change(
    output: &mut String,
    repo_root: &Path,
    raw_path: &str,
    change: &Value,
) -> Result<(), TrajectoryError> {
    let Ok(old_path) = relative_patch_path(repo_root, Path::new(raw_path)) else {
        return Ok(());
    };
    let change_type = change
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("update");
    let new_path = if let Some(path) = change.get("move_path").and_then(Value::as_str) {
        let Ok(path) = relative_patch_path(repo_root, Path::new(path)) else {
            return Ok(());
        };
        path
    } else {
        old_path.clone()
    };
    match change_type {
        "add" => {
            let content = change.get("content").and_then(Value::as_str).unwrap_or("");
            append_added_file(output, &new_path, content)?;
        }
        "delete" => {
            let old_a = git_prefixed_path("a/", &old_path);
            let new_b = git_prefixed_path("b/", &new_path);
            write!(
                output,
                "diff --git {old_a} {new_b}\ndeleted file mode 100644\n--- {old_a}\n+++ /dev/null\n"
            )
            .map_err(|_| TrajectoryError::Invalid)?;
            if let Some(hunks) = change
                .get("unified_diff")
                .and_then(Value::as_str)
                .filter(|hunks| !hunks.trim().is_empty())
            {
                append_patch_fragment(output, hunks)?;
            } else if let Some(content) = change.get("content").and_then(Value::as_str) {
                append_deleted_content(output, content)?;
            } else {
                return Err(TrajectoryError::Invalid);
            }
        }
        _ => {
            let hunks = change
                .get("unified_diff")
                .and_then(Value::as_str)
                .ok_or(TrajectoryError::Invalid)?;
            let old_a = git_prefixed_path("a/", &old_path);
            let new_b = git_prefixed_path("b/", &new_path);
            write!(
                output,
                "diff --git {old_a} {new_b}\n--- {old_a}\n+++ {new_b}\n"
            )
            .map_err(|_| TrajectoryError::Invalid)?;
            append_patch_fragment(output, hunks)?;
        }
    }
    ensure_patch_limit(output)
}

fn append_added_file(
    output: &mut String,
    path: &str,
    content: &str,
) -> Result<(), TrajectoryError> {
    let line_count = content.lines().count();
    let old_a = git_prefixed_path("a/", path);
    let new_b = git_prefixed_path("b/", path);
    if content.is_empty() {
        write!(
            output,
            "diff --git {old_a} {new_b}\nnew file mode 100644\nindex 0000000..e69de29\n"
        )
        .map_err(|_| TrajectoryError::Invalid)?;
        return ensure_patch_limit(output);
    }
    write!(
        output,
        "diff --git {old_a} {new_b}\nnew file mode 100644\n--- /dev/null\n+++ {new_b}\n@@ -0,0 +1,{line_count} @@\n"
    )
    .map_err(|_| TrajectoryError::Invalid)?;
    for line in content.split_inclusive('\n') {
        output.push('+');
        output.push_str(line);
    }
    if !content.is_empty() && !content.ends_with('\n') {
        output.push_str("\n\\ No newline at end of file\n");
    }
    ensure_patch_limit(output)
}

fn claude_last_turn_patch(
    transcript: &Path,
    repo_root: &Path,
    cancellation: &TrajectoryCancellation,
) -> Result<String, TrajectoryError> {
    let mut current_prompt = None::<String>;
    let mut patch = String::new();
    for_json_lines(transcript, cancellation, |object| {
        if object.get("type").and_then(Value::as_str) != Some("user") {
            return Ok(false);
        }
        let prompt_id = object.get("promptId").and_then(Value::as_str);
        if claude_is_prompt_boundary(object) {
            patch.clear();
            current_prompt = prompt_id.map(str::to_owned);
            return Ok(false);
        }
        if prompt_id.is_none() || prompt_id != current_prompt.as_deref() {
            return Ok(false);
        }
        if let Some(result) = object.get("toolUseResult")
            && result
                .get("structuredPatch")
                .and_then(Value::as_array)
                .is_some()
        {
            append_claude_result(&mut patch, repo_root, result)?;
        }
        Ok(false)
    })?;
    if let Some(prompt_id) = current_prompt {
        append_claude_subagent_patches(
            &mut patch,
            transcript,
            repo_root,
            &prompt_id,
            cancellation,
        )?;
    }
    Ok(patch)
}

fn append_claude_subagent_patches(
    output: &mut String,
    parent_transcript: &Path,
    repo_root: &Path,
    prompt_id: &str,
    cancellation: &TrajectoryCancellation,
) -> Result<(), TrajectoryError> {
    let subagent_directory = parent_transcript.with_extension("").join("subagents");
    let entries = match std::fs::read_dir(subagent_directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(_) => return Err(TrajectoryError::Unavailable),
    };
    let mut transcripts = Vec::new();
    for entry in entries {
        cancellation.check()?;
        let entry = entry.map_err(|_| TrajectoryError::Invalid)?;
        let path = entry.path();
        let is_subagent_transcript = path.extension().and_then(|value| value.to_str())
            == Some("jsonl")
            && path
                .file_stem()
                .and_then(|value| value.to_str())
                .is_some_and(|name| name.starts_with("agent-") && name.len() > "agent-".len());
        if is_subagent_transcript {
            transcripts.push(path);
            if transcripts.len() > MAX_CLAUDE_SUBAGENT_TRANSCRIPTS {
                return Err(TrajectoryError::Invalid);
            }
        }
    }
    transcripts.sort_unstable();
    for transcript in transcripts {
        for_json_lines(&transcript, cancellation, |object| {
            if object.get("type").and_then(Value::as_str) != Some("user")
                || object.get("promptId").and_then(Value::as_str) != Some(prompt_id)
            {
                return Ok(false);
            }
            if let Some(result) = object.get("toolUseResult")
                && result
                    .get("structuredPatch")
                    .and_then(Value::as_array)
                    .is_some()
            {
                append_claude_result(output, repo_root, result)?;
            }
            Ok(false)
        })?;
    }
    Ok(())
}

fn claude_is_prompt_boundary(object: &Value) -> bool {
    if object.get("toolUseResult").is_some()
        || object.get("isMeta").and_then(Value::as_bool) == Some(true)
        || object.get("isCompactSummary").and_then(Value::as_bool) == Some(true)
    {
        return false;
    }
    let Some(message) = object.get("message") else {
        return false;
    };
    if message
        .get("role")
        .and_then(Value::as_str)
        .is_some_and(|role| role != "user")
    {
        return false;
    }
    match message.get("content") {
        Some(Value::String(content)) => {
            let content = content.trim_start();
            !content.is_empty()
                && !content.starts_with("<task-notification>")
                && !content.starts_with("<local-command-caveat>")
                && !content.starts_with("[SYSTEM NOTIFICATION - NOT USER INPUT]")
        }
        Some(Value::Array(content)) => {
            !content
                .iter()
                .any(|item| item.get("type").and_then(Value::as_str) == Some("tool_result"))
                && content.iter().any(|item| {
                    matches!(
                        item.get("type").and_then(Value::as_str),
                        Some("text" | "image" | "document")
                    )
                })
        }
        _ => false,
    }
}

fn append_claude_result(
    output: &mut String,
    repo_root: &Path,
    result: &Value,
) -> Result<(), TrajectoryError> {
    let raw_path = result
        .get("filePath")
        .and_then(Value::as_str)
        .ok_or(TrajectoryError::Invalid)?;
    let Ok(path) = relative_patch_path(repo_root, Path::new(raw_path)) else {
        return Ok(());
    };
    let hunks = result
        .get("structuredPatch")
        .and_then(Value::as_array)
        .ok_or(TrajectoryError::Invalid)?;
    let result_type = result.get("type").and_then(Value::as_str);
    let is_create = result_type == Some("create");
    let is_delete = result_type == Some("delete");
    if hunks.is_empty() {
        if is_create {
            let content = result
                .get("content")
                .and_then(Value::as_str)
                .ok_or(TrajectoryError::Invalid)?;
            return append_added_file(output, &path, content);
        }
        if is_delete {
            let content = result
                .get("content")
                .and_then(Value::as_str)
                .ok_or(TrajectoryError::Invalid)?;
            let old_a = git_prefixed_path("a/", &path);
            let new_b = git_prefixed_path("b/", &path);
            write!(
                output,
                "diff --git {old_a} {new_b}\ndeleted file mode 100644\n--- {old_a}\n+++ /dev/null\n"
            )
            .map_err(|_| TrajectoryError::Invalid)?;
            return append_deleted_content(output, content);
        }
        return Ok(());
    }
    let old_a = git_prefixed_path("a/", &path);
    let new_b = git_prefixed_path("b/", &path);
    writeln!(output, "diff --git {old_a} {new_b}").map_err(|_| TrajectoryError::Invalid)?;
    if is_create {
        write!(output, "new file mode 100644\n--- /dev/null\n+++ {new_b}\n")
            .map_err(|_| TrajectoryError::Invalid)?;
    } else if is_delete {
        write!(
            output,
            "deleted file mode 100644\n--- {old_a}\n+++ /dev/null\n"
        )
        .map_err(|_| TrajectoryError::Invalid)?;
    } else {
        write!(output, "--- {old_a}\n+++ {new_b}\n").map_err(|_| TrajectoryError::Invalid)?;
    }
    for hunk in hunks {
        let old_start = hunk
            .get("oldStart")
            .and_then(Value::as_u64)
            .ok_or(TrajectoryError::Invalid)?;
        let old_lines = hunk
            .get("oldLines")
            .and_then(Value::as_u64)
            .ok_or(TrajectoryError::Invalid)?;
        let new_start = hunk
            .get("newStart")
            .and_then(Value::as_u64)
            .ok_or(TrajectoryError::Invalid)?;
        let new_lines = hunk
            .get("newLines")
            .and_then(Value::as_u64)
            .ok_or(TrajectoryError::Invalid)?;
        writeln!(
            output,
            "@@ -{old_start},{old_lines} +{new_start},{new_lines} @@"
        )
        .map_err(|_| TrajectoryError::Invalid)?;
        for line in hunk
            .get("lines")
            .and_then(Value::as_array)
            .ok_or(TrajectoryError::Invalid)?
        {
            output.push_str(line.as_str().ok_or(TrajectoryError::Invalid)?);
            output.push('\n');
        }
    }
    ensure_patch_limit(output)
}

fn for_json_lines(
    path: &Path,
    cancellation: &TrajectoryCancellation,
    mut consume: impl FnMut(&Value) -> Result<bool, TrajectoryError>,
) -> Result<(), TrajectoryError> {
    let file = File::open(path).map_err(|_| TrajectoryError::Unavailable)?;
    let transcript_len = file
        .metadata()
        .map_err(|_| TrajectoryError::Unavailable)?
        .len();
    if transcript_len > MAX_TRANSCRIPT_BYTES {
        return Err(TrajectoryError::Invalid);
    }
    let mut reader = BufReader::new(file.take(transcript_len));
    let mut line = Vec::new();
    while let Some(terminated) = read_capped_json_line(&mut reader, &mut line, cancellation)? {
        cancellation.check()?;
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let object = match serde_json::from_slice::<Value>(&line) {
            Ok(object) => object,
            Err(_) if !terminated => break,
            Err(_) => return Err(TrajectoryError::Invalid),
        };
        if consume(&object)? {
            break;
        }
    }
    Ok(())
}

fn read_capped_json_line(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    cancellation: &TrajectoryCancellation,
) -> Result<Option<bool>, TrajectoryError> {
    line.clear();
    loop {
        cancellation.check()?;
        let (consumed, terminated) = {
            let available = reader.fill_buf().map_err(|_| TrajectoryError::Invalid)?;
            if available.is_empty() {
                return Ok((!line.is_empty()).then_some(false));
            }
            let consumed = available
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(available.len(), |index| index + 1);
            if line.len().saturating_add(consumed) > MAX_JSONL_LINE_BYTES {
                return Err(TrajectoryError::Invalid);
            }
            line.extend_from_slice(&available[..consumed]);
            (consumed, available[consumed - 1] == b'\n')
        };
        reader.consume(consumed);
        if terminated {
            return Ok(Some(true));
        }
    }
}

fn canonical_directory(path: &Path) -> Result<PathBuf, TrajectoryError> {
    let canonical = path
        .canonicalize()
        .map_err(|_| TrajectoryError::Unavailable)?;
    if !canonical.is_dir() {
        return Err(TrajectoryError::Unavailable);
    }
    Ok(canonical)
}

fn canonical_repository_root(path: &Path) -> Result<PathBuf, TrajectoryError> {
    let directory = canonical_directory(path)?;
    Ok(directory
        .ancestors()
        .find(|ancestor| ancestor.join(".git").exists())
        .map_or(directory.clone(), Path::to_path_buf))
}

fn expanded_path(raw: &str) -> PathBuf {
    if raw == "~" {
        return std::env::var_os("HOME").map_or_else(|| PathBuf::from(raw), PathBuf::from);
    }
    if let Some(suffix) = raw.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(suffix);
    }
    PathBuf::from(raw)
}

fn relative_patch_path(repo_root: &Path, path: &Path) -> Result<String, TrajectoryError> {
    let relative = if path.is_absolute() {
        let normalized = canonicalize_with_missing(path)?;
        normalized
            .strip_prefix(repo_root)
            .map_err(|_| TrajectoryError::Invalid)?
            .to_owned()
    } else {
        path.to_owned()
    };
    let mut components = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(value) => components.push(value.to_string_lossy().into_owned()),
            _ => return Err(TrajectoryError::Invalid),
        }
    }
    if components.is_empty() {
        return Err(TrajectoryError::Invalid);
    }
    Ok(components.join("/"))
}

fn git_prefixed_path(prefix: &str, path: &str) -> String {
    git_quote_path(&format!("{prefix}{path}"))
}

fn git_quote_path(path: &str) -> String {
    if !path.chars().any(|character| {
        character.is_whitespace() || character == '"' || character == '\\' || character.is_control()
    }) {
        return path.to_owned();
    }
    let mut quoted = String::from("\"");
    for character in path.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            control if control.is_control() => {
                let mut encoded = [0_u8; 4];
                for byte in control.encode_utf8(&mut encoded).as_bytes() {
                    write!(quoted, "\\{byte:03o}").expect("writing to String cannot fail");
                }
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

fn canonicalize_with_missing(path: &Path) -> Result<PathBuf, TrajectoryError> {
    let mut existing = path;
    let mut suffix = Vec::new();
    while !existing.exists() {
        let name = existing
            .file_name()
            .ok_or(TrajectoryError::Invalid)?
            .to_owned();
        suffix.push(name);
        existing = existing.parent().ok_or(TrajectoryError::Invalid)?;
    }
    let mut normalized = existing
        .canonicalize()
        .map_err(|_| TrajectoryError::Invalid)?;
    for component in suffix.into_iter().rev() {
        normalized.push(component);
    }
    Ok(normalized)
}

fn append_patch_fragment(output: &mut String, fragment: &str) -> Result<(), TrajectoryError> {
    let fragment = fragment.trim_matches('\n');
    if fragment.is_empty() {
        return Ok(());
    }
    output.push_str(fragment);
    output.push('\n');
    ensure_patch_limit(output)
}

fn append_opencode_patch(
    output: &mut String,
    repo_root: &Path,
    fragment: &str,
) -> Result<(), TrajectoryError> {
    let mut saw_path = false;
    let mut in_hunk = false;
    for line in fragment.lines() {
        if line.starts_with("diff --git ") {
            // The ---/+++ pair below is authoritative and can be normalized
            // without trying to split an ambiguously quoted diff --git line.
            in_hunk = false;
            continue;
        }
        if let Some(raw) = line.strip_prefix("Index: ") {
            in_hunk = false;
            let (path, suffix) = split_patch_header_value(raw)?;
            let relative = normalized_opencode_path(repo_root, path, false)?;
            writeln!(output, "Index: {}{suffix}", git_quote_path(&relative))
                .map_err(|_| TrajectoryError::Invalid)?;
            saw_path = true;
            continue;
        }
        if line.starts_with("@@") {
            in_hunk = true;
        }
        if !in_hunk
            && let Some((marker, prefix, raw)) = line
                .strip_prefix("--- ")
                .map(|raw| ("---", "a/", raw))
                .or_else(|| line.strip_prefix("+++ ").map(|raw| ("+++", "b/", raw)))
        {
            let (path, suffix) = split_patch_header_value(raw)?;
            if path == "/dev/null" {
                writeln!(output, "{marker} /dev/null{suffix}")
                    .map_err(|_| TrajectoryError::Invalid)?;
            } else {
                let relative = normalized_opencode_path(repo_root, path, true)?;
                writeln!(
                    output,
                    "{marker} {}{suffix}",
                    git_prefixed_path(prefix, &relative)
                )
                .map_err(|_| TrajectoryError::Invalid)?;
            }
            saw_path = true;
            continue;
        }
        writeln!(output, "{line}").map_err(|_| TrajectoryError::Invalid)?;
    }
    if !saw_path {
        return Err(TrajectoryError::Invalid);
    }
    ensure_patch_limit(output)
}

fn split_patch_header_value(raw: &str) -> Result<(&str, &str), TrajectoryError> {
    if !raw.starts_with('"') {
        return Ok(raw
            .split_once('\t')
            .map_or((raw, ""), |(path, _)| (path, &raw[path.len()..])));
    }
    let mut escaped = false;
    for (index, character) in raw.char_indices().skip(1) {
        if escaped {
            escaped = false;
        } else if character == '\\' {
            escaped = true;
        } else if character == '"' {
            let end = index + character.len_utf8();
            return Ok((&raw[..end], &raw[end..]));
        }
    }
    Err(TrajectoryError::Invalid)
}

fn normalized_opencode_path(
    repo_root: &Path,
    raw: &str,
    strip_git_prefix: bool,
) -> Result<String, TrajectoryError> {
    let decoded = decode_git_quoted_path(raw)?;
    let normalized = if strip_git_prefix && !Path::new(&decoded).is_absolute() {
        decoded
            .strip_prefix("a/")
            .or_else(|| decoded.strip_prefix("b/"))
            .unwrap_or(&decoded)
            .to_owned()
    } else {
        decoded
    };
    relative_patch_path(repo_root, Path::new(&normalized))
}

fn decode_git_quoted_path(raw: &str) -> Result<String, TrajectoryError> {
    if !raw.starts_with('"') {
        return Ok(raw.to_owned());
    }
    if !raw.ends_with('"') || raw.len() < 2 {
        return Err(TrajectoryError::Invalid);
    }
    let bytes = raw.as_bytes();
    let mut decoded = Vec::with_capacity(raw.len() - 2);
    let mut index = 1;
    while index < bytes.len() - 1 {
        if bytes[index] != b'\\' {
            decoded.push(bytes[index]);
            index += 1;
            continue;
        }
        index += 1;
        let escaped = *bytes.get(index).ok_or(TrajectoryError::Invalid)?;
        match escaped {
            b'n' => decoded.push(b'\n'),
            b'r' => decoded.push(b'\r'),
            b't' => decoded.push(b'\t'),
            b'\\' | b'"' => decoded.push(escaped),
            b'0'..=b'7' => {
                let mut value = escaped - b'0';
                let mut digits = 1;
                while digits < 3
                    && index + 1 < bytes.len() - 1
                    && matches!(bytes[index + 1], b'0'..=b'7')
                {
                    index += 1;
                    value = value
                        .checked_mul(8)
                        .and_then(|value| value.checked_add(bytes[index] - b'0'))
                        .ok_or(TrajectoryError::Invalid)?;
                    digits += 1;
                }
                decoded.push(value);
            }
            _ => return Err(TrajectoryError::Invalid),
        }
        index += 1;
    }
    String::from_utf8(decoded).map_err(|_| TrajectoryError::Invalid)
}

fn append_deleted_content(output: &mut String, content: &str) -> Result<(), TrajectoryError> {
    let line_count = content.lines().count();
    if line_count > 0 {
        writeln!(output, "@@ -1,{line_count} +0,0 @@").map_err(|_| TrajectoryError::Invalid)?;
        for line in content.split_inclusive('\n') {
            output.push('-');
            output.push_str(line);
        }
        if !content.ends_with('\n') {
            output.push_str("\n\\ No newline at end of file\n");
        }
    }
    ensure_patch_limit(output)
}

fn ensure_patch_limit(output: &str) -> Result<(), TrajectoryError> {
    if output.len() > MAX_PATCH_BYTES {
        return Err(TrajectoryError::Invalid);
    }
    Ok(())
}

#[cfg(test)]
mod environment_tests {
    use super::*;
    use std::ffi::OsString;
    use std::io::Write as _;

    #[test]
    fn transcript_generation_changes_when_the_trajectory_grows() {
        let path = std::env::temp_dir().join(format!(
            "cmux-transcript-generation-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, b"first turn\n").expect("write transcript");
        let first = transcript_generation(&path).expect("read first generation");

        let mut transcript = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .expect("open transcript");
        transcript
            .write_all(b"second turn\n")
            .expect("append transcript");
        transcript.flush().expect("flush transcript");
        let second = transcript_generation(&path).expect("read second generation");

        assert_ne!(first, second);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn opencode_database_caps_sqlite_value_lengths_before_decoding() {
        let root = std::env::temp_dir().join(format!(
            "cmux-opencode-limit-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).expect("create fixture root");
        let database_path = root.join("opencode.db");
        Connection::open(&database_path).expect("create database");

        let connection = open_opencode_database(&database_path).expect("open bounded database");

        assert_eq!(
            connection
                .limit(rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH)
                .expect("read SQLite length limit"),
            i32::try_from(MAX_PATCH_BYTES).expect("patch limit fits SQLite")
        );
        drop(connection);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn bounded_file_reader_rejects_growth_before_allocating_the_tail() {
        let path = std::env::temp_dir().join(format!(
            "cmux-hook-store-limit-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let file = File::create(&path).expect("create sparse hook store");
        file.set_len(1_025).expect("grow sparse hook store");

        assert!(read_file_capped(&path, 1_024).is_none());

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn claude_fallback_scan_is_cancellable_and_fails_closed_past_its_cap() {
        let root = std::env::temp_dir().join(format!(
            "cmux-claude-scan-limit-test-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        let projects = root.join("projects");
        for index in 0..3 {
            std::fs::create_dir_all(projects.join(format!("project-{index}")))
                .expect("create project directory");
        }
        std::fs::write(projects.join("project-2/session.jsonl"), b"{}\n")
            .expect("write transcript");
        let cancellation = TrajectoryCancellation::default();

        assert!(
            find_claude_transcript_with_limit(&projects, "session", &cancellation, 2).is_none()
        );
        cancellation.cancel();
        assert!(
            find_claude_transcript_with_limit(&projects, "session", &cancellation, 8).is_none()
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn claude_specific_hook_path_wins_and_expands_home() {
        let values = HashMap::from([
            ("HOME", OsString::from("/tmp/cmux-home")),
            (
                "CMUX_AGENT_HOOK_STATE_DIR",
                OsString::from("~/generic-hook-state"),
            ),
            (
                "CMUX_CLAUDE_HOOK_STATE_PATH",
                OsString::from("~/claude/state.json"),
            ),
        ]);
        let roots = TrajectoryRoots::from_environment_values(|key| values.get(key).cloned())
            .expect("resolve fixture environment");

        assert_eq!(
            roots.hook_store(AgentProvider::Claude),
            PathBuf::from("/tmp/cmux-home/claude/state.json")
        );
        assert_eq!(
            roots.hook_store(AgentProvider::Codex),
            PathBuf::from("/tmp/cmux-home/generic-hook-state/codex-hook-sessions.json")
        );
    }

    #[test]
    fn jsonl_scan_stops_at_the_file_length_captured_when_opened() {
        let path = std::env::temp_dir().join(format!(
            "cmux-trajectory-growing-{}-{}.jsonl",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, b"{\"record\":1}\n{\"record\":2}\n")
            .expect("write initial transcript");
        let mut count = 0;

        for_json_lines(&path, &TrajectoryCancellation::default(), |_| {
            count += 1;
            if count == 1 {
                let mut transcript = std::fs::OpenOptions::new()
                    .append(true)
                    .open(&path)
                    .expect("open growing transcript");
                transcript
                    .write_all(b"{\"record\":3}\n")
                    .expect("append concurrent record");
            }
            Ok(false)
        })
        .expect("scan transcript snapshot");
        let _ = std::fs::remove_file(path);

        assert_eq!(count, 2);
    }
}

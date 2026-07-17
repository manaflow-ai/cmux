use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Deserialize;
use serde_json::Value;

use crate::protocol::AgentProvider;

const MAX_SESSION_ID_BYTES: usize = 512;
const MAX_JSONL_LINE_BYTES: usize = 16 * 1024 * 1024;
const MAX_TRANSCRIPT_BYTES: u64 = 512 * 1024 * 1024;
const MAX_PATCH_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentTurnIdentity {
    pub provider: AgentProvider,
    pub session_id: String,
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
}

impl TrajectoryRoots {
    #[must_use]
    pub fn for_home(home: PathBuf) -> Self {
        Self {
            home,
            hook_state_dir: None,
        }
    }

    /// Resolves trajectory storage from the current process environment.
    ///
    /// # Errors
    ///
    /// Returns [`TrajectoryError::Unavailable`] when `HOME` is unset or empty.
    pub fn from_environment() -> Result<Self, TrajectoryError> {
        let home = std::env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .ok_or(TrajectoryError::Unavailable)?;
        let hook_state_dir = std::env::var_os("CMUX_AGENT_HOOK_STATE_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        Ok(Self {
            home,
            hook_state_dir,
        })
    }

    fn hook_store(&self, provider: AgentProvider) -> PathBuf {
        let name = match provider {
            AgentProvider::Codex => "codex",
            AgentProvider::Claude => "claude",
            AgentProvider::OpenCode => "opencode",
        };
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedTurnPatch {
    pub repo_root: PathBuf,
    pub patch: String,
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
    validate_session_id(&identity.session_id)?;
    match identity.provider {
        AgentProvider::Codex => resolve_codex(identity, roots),
        AgentProvider::Claude => resolve_claude(identity, roots),
        AgentProvider::OpenCode => resolve_opencode(identity, roots),
    }
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

fn resolve_codex(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
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
        let (transcript, repo_root) =
            read_codex_database_record(&roots.codex_database(), &identity.session_id)
                .ok_or(TrajectoryError::Unavailable)?;
        (
            expanded_path(&transcript),
            expanded_path(repo_root.as_deref().ok_or(TrajectoryError::Unavailable)?),
        )
    };
    let repo_root = canonical_repository_root(&repo_root)?;
    let patch = codex_last_turn_patch(&transcript, &repo_root)?;
    finish(repo_root, patch)
}

fn resolve_claude(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
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
        let transcript = find_claude_transcript(roots, &identity.session_id)
            .ok_or(TrajectoryError::Unavailable)?;
        let repo_root = claude_transcript_cwd(&transcript).ok_or(TrajectoryError::Unavailable)?;
        (transcript, repo_root)
    };
    let repo_root = canonical_repository_root(&repo_root)?;
    let patch = claude_last_turn_patch(&transcript, &repo_root)?;
    finish(repo_root, patch)
}

fn resolve_opencode(
    identity: &AgentTurnIdentity,
    roots: &TrajectoryRoots,
) -> Result<ResolvedTurnPatch, TrajectoryError> {
    let connection = open_read_only_database(&roots.opencode_database())?;
    let repo: String = connection
        .query_row(
            "SELECT directory FROM session WHERE id = ?1 LIMIT 1",
            [&identity.session_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| TrajectoryError::Invalid)?
        .ok_or(TrajectoryError::Unavailable)?;
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
        append_patch_fragment(&mut patch, &row.map_err(|_| TrajectoryError::Invalid)?)?;
    }
    let repo_root = canonical_repository_root(&expanded_path(&repo))?;
    finish(repo_root, patch)
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
    let bytes = std::fs::read(roots.hook_store(provider)).ok()?;
    if bytes.len() > MAX_JSONL_LINE_BYTES {
        return None;
    }
    serde_json::from_slice::<HookStore>(&bytes)
        .ok()?
        .sessions
        .get(session_id)
        .cloned()
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

fn find_claude_transcript(roots: &TrajectoryRoots, session_id: &str) -> Option<PathBuf> {
    let filename = format!("{session_id}.jsonl");
    for entry in std::fs::read_dir(roots.claude_projects()).ok()?.flatten() {
        let candidate = entry.path().join(&filename);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn claude_transcript_cwd(transcript: &Path) -> Option<PathBuf> {
    let mut cwd = None;
    for_json_lines(transcript, |object| {
        cwd = object.get("cwd").and_then(Value::as_str).map(expanded_path);
        Ok(cwd.is_some())
    })
    .ok()?;
    cwd
}

fn codex_last_turn_patch(transcript: &Path, repo_root: &Path) -> Result<String, TrajectoryError> {
    let mut current_turn = None::<String>;
    let mut patch = String::new();
    for_json_lines(transcript, |object| {
        let Some(payload) = object
            .get("payload")
            .filter(|_| object.get("type").and_then(Value::as_str) == Some("event_msg"))
        else {
            return Ok(false);
        };
        let event_type = payload.get("type").and_then(Value::as_str);
        let turn_id = payload.get("turn_id").and_then(Value::as_str);
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
            || payload.get("success") == Some(&Value::Bool(false))
        {
            return Ok(false);
        }
        let Some(turn_id) = turn_id else {
            return Ok(false);
        };
        if current_turn.as_deref() != Some(turn_id) {
            current_turn = Some(turn_id.to_owned());
            patch.clear();
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

fn claude_last_turn_patch(transcript: &Path, repo_root: &Path) -> Result<String, TrajectoryError> {
    let mut current_prompt = None::<String>;
    let mut patch = String::new();
    for_json_lines(transcript, |object| {
        if object.get("type").and_then(Value::as_str) != Some("user") {
            return Ok(false);
        }
        let prompt_id = object.get("promptId").and_then(Value::as_str);
        if object.get("toolUseResult").is_none() {
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
    Ok(patch)
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
    let is_create = result.get("type").and_then(Value::as_str) == Some("create");
    if hunks.is_empty() {
        if is_create {
            let content = result
                .get("content")
                .and_then(Value::as_str)
                .ok_or(TrajectoryError::Invalid)?;
            return append_added_file(output, &path, content);
        }
        return Ok(());
    }
    let old_a = git_prefixed_path("a/", &path);
    let new_b = git_prefixed_path("b/", &path);
    writeln!(output, "diff --git {old_a} {new_b}").map_err(|_| TrajectoryError::Invalid)?;
    if is_create {
        write!(output, "new file mode 100644\n--- /dev/null\n+++ {new_b}\n")
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
    mut consume: impl FnMut(&Value) -> Result<bool, TrajectoryError>,
) -> Result<(), TrajectoryError> {
    let file = File::open(path).map_err(|_| TrajectoryError::Unavailable)?;
    if file
        .metadata()
        .map_err(|_| TrajectoryError::Unavailable)?
        .len()
        > MAX_TRANSCRIPT_BYTES
    {
        return Err(TrajectoryError::Invalid);
    }
    let mut reader = BufReader::new(file);
    let mut line = Vec::new();
    while read_capped_json_line(&mut reader, &mut line)? {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let object =
            serde_json::from_slice::<Value>(&line).map_err(|_| TrajectoryError::Invalid)?;
        if consume(&object)? {
            break;
        }
    }
    Ok(())
}

fn read_capped_json_line(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
) -> Result<bool, TrajectoryError> {
    line.clear();
    loop {
        let (consumed, terminated) = {
            let available = reader.fill_buf().map_err(|_| TrajectoryError::Invalid)?;
            if available.is_empty() {
                return Ok(!line.is_empty());
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
            return Ok(true);
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

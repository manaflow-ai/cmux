//! Adopting a harness's own session (`session/new` with
//! `_meta.acpmux.adopt = {harness, agentSessionId}`): a Claude Code, Codex
//! or OpenCode conversation started outside acpmux becomes an acpmux session
//! that resumes it (`claude --resume <id>`, or ACP `session/load`).
//!
//! The id comes from a client, so it is checked before it names a file: a
//! bare id only, found in the harness's own store, or the request fails.
//! The store's record also gives the conversation's working directory,
//! which a resumed harness needs (Claude keys its projects by cwd).

use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

/// What `_meta.acpmux.adopt` asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdoptRequest {
    /// The harness (profile or family) whose session this is.
    pub harness: Option<String>,
    /// The harness's own session id.
    pub agent_session_id: String,
    /// What to do when the session is live in another process (`adopt_live`).
    pub if_live: IfLive,
    /// `adopt.cwdMap` (`FROM=TO`): where another machine's folders are here,
    /// for a chat whose recorded folder is gone (`hub/adoption.rs`).
    pub cwd_map: Vec<(PathBuf, PathBuf)>,
    /// `adopt.watch`: show the conversation and follow its transcript without starting a harness
    /// on it, until a client takes it over (`hub/watch.rs`).
    pub watch: bool,
}

/// `adopt.ifLive`: a chat live in another process is refused (the
/// default), forked into a new chat (Claude Code only), or opened anyway.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum IfLive {
    #[default]
    Refuse,
    Fork,
    Open,
}

impl IfLive {
    /// `ifLive` as `adopt` and `_acpmux/watch_take_over` take it: absent is `refuse`.
    pub fn parse(value: Option<&str>) -> Result<Self, String> {
        match value {
            None | Some("refuse") => Ok(IfLive::Refuse),
            Some("fork") => Ok(IfLive::Fork),
            Some("open") => Ok(IfLive::Open),
            Some(other) => Err(format!("ifLive {other:?} is not refuse, fork or open")),
        }
    }
}

impl AdoptRequest {
    /// Reads `{harness, agentSessionId, ifLive?, cwdMap?, watch?}`; `None` when
    /// absent, an error when malformed.
    pub fn from_meta(meta: Option<&Value>) -> Result<Option<Self>, String> {
        let Some(adopt) = meta.and_then(|m| m.get("adopt")) else { return Ok(None) };
        let id = adopt
            .get("agentSessionId")
            .and_then(Value::as_str)
            .ok_or("adopt needs agentSessionId")?;
        let harness = adopt.get("harness").and_then(Value::as_str).map(str::to_owned);
        let if_live = IfLive::parse(adopt.get("ifLive").and_then(Value::as_str))
            .map_err(|e| format!("adopt {e}"))?;
        let cwd_map = match adopt.get("cwdMap") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|item| {
                    item.as_str().and_then(parse_cwd_map).ok_or_else(|| {
                        format!("adopt cwdMap entry {item} is not FROM=TO with absolute folders")
                    })
                })
                .collect::<Result<_, _>>()?,
            Some(other) => return Err(format!("adopt cwdMap {other} is not a list of FROM=TO")),
        };
        let watch = adopt.get("watch").and_then(Value::as_bool).unwrap_or(false);
        Ok(Some(Self { harness, agent_session_id: id.to_owned(), if_live, cwd_map, watch }))
    }
}

/// One `FROM=TO` cwd map entry; both folders absolute.
pub fn parse_cwd_map(text: &str) -> Option<(PathBuf, PathBuf)> {
    let (from, to) = text.split_once('=')?;
    let (from, to) = (PathBuf::from(from), PathBuf::from(to));
    (from.is_absolute() && to.is_absolute()).then_some((from, to))
}

/// Where the harnesses keep their sessions: `CLAUDE_CONFIG_DIR` (else
/// `~/.claude`) and `CODEX_HOME` (else `~/.codex`), from the daemon's
/// environment, else the imported login shell environment.
#[derive(Debug, Clone)]
pub struct HarnessHomes {
    pub claude: PathBuf,
    pub codex: PathBuf,
}

impl HarnessHomes {
    pub fn from_env() -> Self {
        let home = dirs::home_dir().unwrap_or_default();
        let dir = |key: &str, default: &str| {
            crate::chats::login_var(key).map(PathBuf::from).unwrap_or_else(|| home.join(default))
        };
        Self { claude: dir("CLAUDE_CONFIG_DIR", ".claude"), codex: dir("CODEX_HOME", ".codex") }
    }

    /// These homes with the `CLAUDE_CONFIG_DIR` / `CODEX_HOME` of spawn env
    /// layers on top, later layers winning: the store a profile's harness
    /// really uses. A value that is not an absolute path (a `${...}`
    /// template, a relative path) is skipped.
    pub fn with_env(&self, layers: &[&std::collections::BTreeMap<String, String>]) -> Self {
        let mut out = self.clone();
        for env in layers {
            let path = |key: &str| {
                env.get(key)
                    .filter(|v| !v.contains('$'))
                    .map(PathBuf::from)
                    .filter(|p| p.is_absolute())
            };
            if let Some(claude) = path("CLAUDE_CONFIG_DIR") {
                out.claude = claude;
            }
            if let Some(codex) = path("CODEX_HOME") {
                out.codex = codex;
            }
        }
        out
    }
}

/// A session found in a harness store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Adoptable {
    pub file: PathBuf,
    /// The working directory the store recorded for it, if any.
    pub cwd: Option<PathBuf>,
}

/// True for an id that can only name one file: letters, digits, `-` and
/// `_`, at most 128 of them (UUIDs and Codex's UUIDv7 ids qualify).
pub fn is_bare_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Finds `id` in the store of harness `family` (`claude`, `codex` or
/// `opencode`). OpenCode's store is its data dir, where the chat index looks.
pub fn find(family: &str, id: &str, homes: &HarnessHomes) -> Result<Adoptable, String> {
    if !is_bare_id(id) {
        return Err(format!("agentSessionId {id:?} is not a session id"));
    }
    let stores = match family {
        "claude" => vec![homes.claude.clone()],
        "codex" => vec![homes.codex.clone()],
        "opencode" => opencode_stores(),
        other => return Err(format!("adopt is not supported for {other} sessions")),
    };
    stores
        .iter()
        .find_map(|store| find_in(family, id, store))
        .ok_or_else(|| format!("no {family} session {id}"))
}

/// `id` in the one store `store` of `family`.
fn find_in(family: &str, id: &str, store: &Path) -> Option<Adoptable> {
    let file = match family {
        "claude" => find_claude(store, id)?,
        "codex" => find_codex(store, id)?,
        "opencode" => {
            // One DB holds every OpenCode chat; it records the folder in the session row.
            let (db, cwd) = cmux_chat_index::find_opencode_session(store, id)?;
            return Some(Adoptable { file: db, cwd: cwd.map(PathBuf::from) });
        }
        _ => return None,
    };
    let cwd = recorded_cwd(family, &file);
    Some(Adoptable { file, cwd })
}

/// OpenCode's data dirs, as the chat index finds them (`$XDG_DATA_HOME/opencode`, then the
/// platform's defaults).
fn opencode_stores() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    cmux_chat_index::default_roots(
        cmux_chat_index::AdapterKind::OpenCode,
        cmux_chat_index::Platform::current(),
        &home,
        &crate::chats::login_var,
    )
    .into_iter()
    .map(|(root, _)| root)
    .collect()
}

/// `find` in `homes`, else in one of `others`: the stores acpmux's own chat
/// index holds the chat in (cx-vx54), never a path from a request. The
/// second value names the other store the session was found in.
pub fn find_any(
    family: &str,
    id: &str,
    homes: &HarnessHomes,
    others: &[PathBuf],
) -> Result<(Adoptable, Option<PathBuf>), String> {
    match find(family, id, homes) {
        Ok(found) => Ok((found, None)),
        // `find` refused an id that is not bare before it named a file; so do the others.
        Err(error) if !is_bare_id(id) => Err(error),
        Err(error) => others
            .iter()
            .find_map(|store| find_in(family, id, store).map(|found| (found, Some(store.clone()))))
            .ok_or(error),
    }
}

/// Whether the Claude store at `root` (a CLAUDE_CONFIG_DIR) has session `id`.
pub fn claude_session_exists(root: &Path, id: &str) -> bool {
    is_bare_id(id) && find_claude(root, id).is_some()
}

/// Lines [`claude_transcript_is_empty`] reads before it calls a transcript stored.
const CONVERSATION_SCAN_LINES: usize = 400;

/// Whether the Claude store at `root` holds session `id`'s file but no conversation in it: no
/// `user` or `assistant` record, only the metadata Claude Code appends when a process exits
/// (`last-prompt`, `cost-state`, `pr-link`). `claude --resume` of such an id fails with "No
/// conversation found with session ID" on every start: 13 chats of Aziz's Mac, 2026-11-02, whose
/// transcripts lost their messages while their processes still ran; each exit at the 13:10
/// restart then wrote this stub. False when the file is absent (a remote or other store: nothing
/// to say) or holds a record of the conversation within its first lines.
pub fn claude_transcript_is_empty(root: &Path, id: &str) -> bool {
    if !is_bare_id(id) {
        return false;
    }
    // Claude Code keeps one folder per working directory: a stub in one may sit beside the real
    // conversation in another, so the store is empty only when no copy holds a conversation.
    let name = format!("{id}.jsonl");
    let Ok(projects) = std::fs::read_dir(root.join("projects")) else { return false };
    let mut found = false;
    for project in projects.flatten() {
        let file = project.path().join(&name);
        if !file.is_file() {
            continue;
        }
        found = true;
        if !file_has_no_conversation(&file) {
            return false;
        }
    }
    found
}

/// Whether one Claude transcript file holds no `user` or `assistant` record in its first
/// [`CONVERSATION_SCAN_LINES`] lines. False when it cannot be read or is longer.
fn file_has_no_conversation(file: &Path) -> bool {
    let Ok(file) = std::fs::File::open(file) else { return false };
    let mut lines = 0usize;
    for line in BufReader::new(file).lines() {
        let Ok(line) = line else { return false };
        lines += 1;
        if lines > CONVERSATION_SCAN_LINES {
            return false;
        }
        #[derive(serde::Deserialize)]
        struct Kind<'a> {
            #[serde(rename = "type", borrow)]
            kind: Option<std::borrow::Cow<'a, str>>,
        }
        let Ok(record) = serde_json::from_str::<Kind<'_>>(&line) else { continue };
        if matches!(record.kind.as_deref(), Some("user" | "assistant")) {
            return false;
        }
    }
    true
}

/// `<claude>/projects/<project>/<id>.jsonl`.
pub(crate) fn find_claude(root: &Path, id: &str) -> Option<PathBuf> {
    let name = format!("{id}.jsonl");
    std::fs::read_dir(root.join("projects"))
        .ok()?
        .flatten()
        .map(|project| project.path().join(&name))
        .find(|file| file.is_file())
}

/// `<codex>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
pub(crate) fn find_codex(root: &Path, id: &str) -> Option<PathBuf> {
    let suffix = format!("-{id}.jsonl");
    let mut dirs = vec![(root.join("sessions"), 0)];
    while let Some((dir, depth)) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() && depth < 3 {
                dirs.push((path, depth + 1));
            } else if kind.is_file()
                && path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("rollout-") && n.ends_with(&suffix))
            {
                return Some(path);
            }
        }
    }
    None
}

/// The cwd in the first records that carry one: a Claude line's `cwd`, or
/// Codex's `session_meta` payload. Reads at most 200 lines.
fn recorded_cwd(family: &str, file: &Path) -> Option<PathBuf> {
    let reader = BufReader::new(std::fs::File::open(file).ok()?);
    for line in reader.lines().take(200).map_while(Result::ok) {
        let Ok(record) = serde_json::from_str::<Value>(&line) else { continue };
        let cwd = match family {
            "codex" => (record.get("type").and_then(Value::as_str) == Some("session_meta"))
                .then(|| record.pointer("/payload/cwd"))
                .flatten(),
            _ => record.get("cwd"),
        };
        if let Some(cwd) = cwd.and_then(Value::as_str).filter(|c| !c.is_empty()) {
            return Some(PathBuf::from(cwd));
        }
    }
    None
}

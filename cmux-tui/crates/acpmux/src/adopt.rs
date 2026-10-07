//! Adopting a harness's own session (`session/new` with
//! `_meta.acpmux.adopt = {harness, agentSessionId}`): a Claude Code or Codex
//! conversation started outside acpmux becomes an acpmux session that
//! resumes it (`claude --resume <id>`, or ACP `session/load` for Codex).
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

impl AdoptRequest {
    /// Reads `{harness, agentSessionId, ifLive?}`; `None` when absent, an
    /// error when malformed.
    pub fn from_meta(meta: Option<&Value>) -> Result<Option<Self>, String> {
        let Some(adopt) = meta.and_then(|m| m.get("adopt")) else { return Ok(None) };
        let id = adopt
            .get("agentSessionId")
            .and_then(Value::as_str)
            .ok_or("adopt needs agentSessionId")?;
        let harness = adopt.get("harness").and_then(Value::as_str).map(str::to_owned);
        let if_live = match adopt.get("ifLive").and_then(Value::as_str) {
            None | Some("refuse") => IfLive::Refuse,
            Some("fork") => IfLive::Fork,
            Some("open") => IfLive::Open,
            Some(other) => {
                return Err(format!("adopt ifLive {other:?} is not refuse, fork or open"));
            }
        };
        Ok(Some(Self { harness, agent_session_id: id.to_owned(), if_live }))
    }
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

/// Finds `id` in the store of harness `family` (`claude` or `codex`).
pub fn find(family: &str, id: &str, homes: &HarnessHomes) -> Result<Adoptable, String> {
    if !is_bare_id(id) {
        return Err(format!("agentSessionId {id:?} is not a session id"));
    }
    let file = match family {
        "claude" => find_claude(&homes.claude, id),
        "codex" => find_codex(&homes.codex, id),
        other => return Err(format!("adopt is not supported for {other} sessions")),
    }
    .ok_or_else(|| format!("no {family} session {id}"))?;
    let cwd = recorded_cwd(family, &file);
    Ok(Adoptable { file, cwd })
}

/// `<claude>/projects/<project>/<id>.jsonl`.
fn find_claude(root: &Path, id: &str) -> Option<PathBuf> {
    let name = format!("{id}.jsonl");
    std::fs::read_dir(root.join("projects"))
        .ok()?
        .flatten()
        .map(|project| project.path().join(&name))
        .find(|file| file.is_file())
}

/// `<codex>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`.
fn find_codex(root: &Path, id: &str) -> Option<PathBuf> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A fresh pair of harness homes with no sessions.
    fn homes() -> HarnessHomes {
        let root = std::env::temp_dir().join(format!("acpmux-adopt-{}", uuid::Uuid::now_v7()));
        HarnessHomes { claude: root.join("claude"), codex: root.join("codex") }
    }

    fn write(path: &Path, lines: &[Value]) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
        std::fs::write(path, text).unwrap();
    }

    const CLAUDE_ID: &str = "8f2c7a5e-1b3d-4c6e-9f00-112233445566";
    const CODEX_ID: &str = "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b";

    #[test]
    fn adopt_meta_reads_harness_and_id() {
        let meta = json!({"adopt": {"harness": "claude", "agentSessionId": CLAUDE_ID}});
        let req = AdoptRequest::from_meta(Some(&meta)).unwrap().unwrap();
        assert_eq!(
            req,
            AdoptRequest {
                harness: Some("claude".into()),
                agent_session_id: CLAUDE_ID.into(),
                if_live: IfLive::Refuse,
            }
        );
        assert_eq!(AdoptRequest::from_meta(Some(&json!({}))).unwrap(), None);
        assert!(AdoptRequest::from_meta(Some(&json!({"adopt": {"harness": "claude"}}))).is_err());
        let fork = json!({"adopt": {"agentSessionId": CLAUDE_ID, "ifLive": "fork"}});
        assert_eq!(AdoptRequest::from_meta(Some(&fork)).unwrap().unwrap().if_live, IfLive::Fork);
        let bad = json!({"adopt": {"agentSessionId": CLAUDE_ID, "ifLive": "steal"}});
        assert!(AdoptRequest::from_meta(Some(&bad)).is_err());
    }

    #[test]
    fn adopt_finds_a_claude_session_and_its_cwd() {
        let homes = homes();
        let file = homes.claude.join("projects/-Users-me-app").join(format!("{CLAUDE_ID}.jsonl"));
        write(
            &file,
            &[
                json!({"type": "summary"}),
                json!({"type": "user", "cwd": "/Users/me/app", "sessionId": CLAUDE_ID}),
            ],
        );
        let found = find("claude", CLAUDE_ID, &homes).unwrap();
        assert_eq!(found, Adoptable { file, cwd: Some("/Users/me/app".into()) });
        let _ = std::fs::remove_dir_all(homes.claude.parent().unwrap());
    }

    #[test]
    fn adopt_finds_a_codex_rollout_and_its_cwd() {
        let homes = homes();
        let file = homes
            .codex
            .join(format!("sessions/2026/10/02/rollout-2026-10-02T09-00-00-{CODEX_ID}.jsonl"));
        write(
            &file,
            &[json!({"type": "session_meta", "payload": {"id": CODEX_ID, "cwd": "/Users/me/api"}})],
        );
        let found = find("codex", CODEX_ID, &homes).unwrap();
        assert_eq!(found, Adoptable { file, cwd: Some("/Users/me/api".into()) });
        let _ = std::fs::remove_dir_all(homes.codex.parent().unwrap());
    }

    /// Fails closed: an unknown id, another harness's id, a path-shaped id
    /// and an unsupported harness are all refused.
    #[test]
    fn adopt_refuses_what_it_cannot_find_or_trust() {
        let homes = homes();
        let file = homes.claude.join("projects/p").join(format!("{CLAUDE_ID}.jsonl"));
        write(&file, &[json!({"cwd": "/tmp"})]);
        assert!(
            find("claude", "8f2c7a5e-0000-0000-0000-000000000000", &homes)
                .unwrap_err()
                .contains("no claude session")
        );
        assert!(find("codex", CLAUDE_ID, &homes).is_err());
        let long = "a".repeat(129);
        for bad in ["../p/x", "a/b", "..", "", "x.jsonl", long.as_str()] {
            assert!(!is_bare_id(bad), "{bad:?}");
            assert!(find("claude", bad, &homes).unwrap_err().contains("not a session id"));
        }
        assert!(find("gemini", CLAUDE_ID, &homes).unwrap_err().contains("not supported"));
        let _ = std::fs::remove_dir_all(homes.claude.parent().unwrap());
    }

    #[test]
    fn adopt_tolerates_a_session_without_a_recorded_cwd() {
        let homes = homes();
        let file = homes.claude.join("projects/p").join(format!("{CLAUDE_ID}.jsonl"));
        write(&file, &[json!({"type": "summary"})]);
        assert_eq!(find("claude", CLAUDE_ID, &homes).unwrap().cwd, None);
        let _ = std::fs::remove_dir_all(homes.claude.parent().unwrap());
    }
}

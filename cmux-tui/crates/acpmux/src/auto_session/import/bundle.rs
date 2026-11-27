//! The copy's events as a session bundle on disk, the form the hub imports a moved chat from
//! (`hub/transfer.rs` `import_into`): `session.json`, `events/000001.ndjson`, `manifest.json`,
//! and the agent's own session files under `native` (and `harness`), as a manual move's bundle
//! has them.

use std::io::Write as _;
use std::path::Path;

use cmux_auto_session::wire::{Manifest, SeqRecord, SessionView};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use crate::auto_session::export::native::{AgentFile, HARNESS_FILES, HARNESS_LABEL, HARNESS_SPEC};
use crate::store::{EventRecord, SessionMeta};

/// The agent conversation a chat goes on with on this machine, and what the import does with
/// the agent's own files of the copy.
pub(super) struct AgentSide<'a> {
    /// The agent session the chat resumes here.
    pub session: String,
    /// The agent's own files that go into its store here.
    pub files: &'a [AgentFile],
    /// The chat ran this conversation on this machine before, so the agent's files of it that
    /// are here are this chat's own and the copy's replace them. Otherwise a file that is here
    /// is left as it is, as a move by hand leaves it.
    pub own: bool,
}

/// What a copy's agent conversation is to this machine. `stored` is the agent session of the
/// chat as it is here, None for a chat that is new here. `taken`: another chat of this daemon
/// keeps the conversation the copy names.
///
/// A copy is written by whoever holds the chat, and one chat's copy must not change another
/// chat's agent memory. So a conversation another chat keeps is not this chat's, whatever the
/// copy says: the chat goes on with the conversation it has here, and none of the copy's agent
/// files are placed. Its log, its folder and its queue are the copy's all the same.
pub(super) fn agent_side<'a>(
    stored: Option<String>,
    manifest: &Manifest,
    files: &'a [AgentFile],
    taken: bool,
) -> AgentSide<'a> {
    let named = manifest.harness_session_id.as_str();
    if taken {
        return AgentSide { session: stored.unwrap_or_default(), files: &[], own: false };
    }
    let own = !named.is_empty() && stored.as_deref() == Some(named);
    AgentSide { session: named.to_owned(), files, own }
}

/// The chat's `session.json`: the chat as it is here (`base`) when it is, else a new one of the
/// manifest's harness. Either way its folder is `dir` and its agent session `agent_session`
/// ([`agent_side`]). `family` is the agent family of that harness on this machine, which says
/// whose session store the chat's agent files belong to (`native.rs` `store_kind`).
pub(super) fn meta(
    view: &SessionView,
    manifest: &Manifest,
    agent_session: &str,
    dir: &Path,
    base: Option<SessionMeta>,
    family: Option<String>,
) -> Result<Value, String> {
    let mut meta = match base {
        Some(base) => serde_json::to_value(base).map_err(|e| format!("the chat's meta: {e}"))?,
        None => {
            let now = crate::store::now_ms();
            let plain = |c: char| if c.is_ascii_alphanumeric() { c } else { '-' };
            let short: String = view.id.chars().take(12).map(plain).collect();
            let mut meta = json!({
                "schema": "acpmux.session.v1", "id": view.id, "name": format!("auto-{short}"),
                "status": "idle", "createdAt": now, "updatedAt": now,
            });
            if !view.title.trim().is_empty() {
                meta.set("title", json!(view.title));
            }
            if let Some(family) = family {
                meta.set("family", json!(family));
            }
            meta
        }
    };
    meta.set("id", json!(view.id));
    meta.set("harness", json!(manifest.harness));
    meta.set("cwd", json!(dir));
    meta.set("agentSessionId", json!(agent_session));
    Ok(meta)
}

/// Puts the agent's own files into the bundle `staged` where a moved chat's bundle has them:
/// under `native`, and cmux-harness's under `harness`. Answers the bundle manifest's `native`
/// list and its `harness` value. The hub's import places them from there
/// (`hub/transfer.rs` `import_placing`), which takes only the files of the chat's own agent
/// session.
fn agent_files(staged: &Path, files: &[AgentFile]) -> Result<(Vec<Value>, Value), String> {
    use std::path::Component;
    let io = |what: &str, error: std::io::Error| format!("the agent's {what}: {error}");
    let (mut native, mut harness) = (Vec::new(), Value::Null);
    for file in files {
        let (label, path) = (file.label.as_str(), file.path.as_str());
        let rel = Path::new(path);
        let inside = rel.components().all(|part| matches!(part, Component::Normal(_)));
        if path.is_empty() || !inside {
            return Err(format!("the copy names an agent file outside its bundle: {path:?}"));
        }
        let target = if label != HARNESS_LABEL {
            native.push(json!({ "label": label, "path": path }));
            staged.join("native").join(rel)
        } else if path == HARNESS_SPEC {
            harness = serde_json::from_slice(&file.bytes)
                .map_err(|e| format!("cmux-harness's manifest in the copy: {e}"))?;
            continue;
        } else if HARNESS_FILES.contains(&path) {
            staged.join("harness").join(rel)
        } else {
            return Err(format!("the copy names an unknown cmux-harness file: {path:?}"));
        };
        if let Some(parent) = target.parent() {
            crate::home_fs::create_dirs(parent).map_err(|e| io(path, e))?;
        }
        crate::home_fs::write(&target, &file.bytes).map_err(|e| io(path, e))?;
    }
    Ok((native, harness))
}

/// Writes the bundle into `staged`. Each event must be one of the chat's log records, numbered
/// as the store numbers it. `files` are the agent's own session files of the copy.
pub(super) fn write(
    staged: &Path,
    id: &str,
    meta: &Value,
    events: &[SeqRecord],
    files: &[AgentFile],
) -> Result<(), String> {
    let io = |what: &str, error: std::io::Error| format!("{what}: {error}");
    std::fs::create_dir_all(staged.join("events")).map_err(|e| io("the bundle's folder", e))?;
    std::fs::write(staged.join("session.json"), meta.to_string())
        .map_err(|e| io("session.json", e))?;
    let (native, harness) = agent_files(staged, files)?;
    let manifest = json!({
        "schema": "acpmux.bundle.v1", "id": id, "native": native, "harness": harness,
    });
    std::fs::write(staged.join("manifest.json"), manifest.to_string())
        .map_err(|e| io("manifest.json", e))?;
    let log = std::fs::File::create(staged.join("events").join("000001.ndjson"))
        .map_err(|e| io("the bundle's log", e))?;
    let mut log = std::io::BufWriter::new(log);
    for event in events {
        let record: EventRecord = serde_json::from_value(event.record.clone())
            .map_err(|e| format!("event {} is not a chat record: {e}", event.seq))?;
        if record.seq != event.seq {
            let (inner, outer) = (record.seq, event.seq);
            return Err(format!("event {outer} holds the chat record numbered {inner}"));
        }
        let line = serde_json::to_string(&record)
            .map_err(|e| format!("event {outer}: {e}", outer = event.seq))?;
        writeln!(log, "{line}").map_err(|e| io("the bundle's log", e))?;
    }
    log.flush().map_err(|e| io("the bundle's log", e))
}

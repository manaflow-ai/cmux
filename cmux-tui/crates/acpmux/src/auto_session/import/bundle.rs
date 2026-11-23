//! The copy's events as a session bundle on disk, the form the hub imports a moved chat from
//! (`hub/transfer.rs` `import_into`): `session.json`, `events/000001.ndjson`, `manifest.json`.

use std::io::Write as _;
use std::path::Path;

use cmux_auto_session::wire::{Manifest, SeqRecord, SessionView};
use serde_json::{Value, json};

use crate::store::{EventRecord, SessionMeta};

/// The chat's `session.json`: the chat as it is here (`base`) when it is, else a new one of the
/// manifest's harness. Either way its folder is `dir` and its agent session the manifest's.
pub(super) fn meta(
    view: &SessionView,
    manifest: &Manifest,
    dir: &Path,
    base: Option<SessionMeta>,
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
                meta["title"] = json!(view.title);
            }
            meta
        }
    };
    meta["id"] = json!(view.id);
    meta["harness"] = json!(manifest.harness);
    meta["cwd"] = json!(dir);
    meta["agentSessionId"] = json!(manifest.harness_session_id);
    Ok(meta)
}

/// Writes the bundle into `staged`. Each event must be one of the chat's log records, numbered
/// as the store numbers it.
pub(super) fn write(
    staged: &Path,
    id: &str,
    meta: &Value,
    events: &[SeqRecord],
) -> Result<(), String> {
    let io = |what: &str, error: std::io::Error| format!("{what}: {error}");
    std::fs::create_dir_all(staged.join("events")).map_err(|e| io("the bundle's folder", e))?;
    std::fs::write(staged.join("session.json"), meta.to_string())
        .map_err(|e| io("session.json", e))?;
    let manifest = json!({ "schema": "acpmux.bundle.v1", "id": id, "harness": null });
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

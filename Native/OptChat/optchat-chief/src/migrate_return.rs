//! A Chief moving back out of the cloud (plans/cmux-next/chief-migration-DESIGN.md 4b).
//!
//! A home that moved to a hosted Cloud Chief keeps its frozen copy and a
//! `state/moved.json` naming `cloud:<api>/<agent>`. `optchat-chief move --to
//! local:DIR|ssh:HOST[:DIR]` on that home brings the Chief out again:
//!
//! 1. **Freeze**: the hosted brain goes off and the move waits until no Cloud
//!    turn runs, so the cloud copy writes nothing more (one writer).
//! 2. **Export**: the hosted memory (`GET /v1/chiefs/<id>/memory?export=1`,
//!    pages) and the main conversation's messages after the ones the move
//!    copied in (`conversation.history`).
//! 3. **Merge** into a checkpoint of the frozen home: the memory messages and
//!    summary nodes the cloud added, the conversation messages it got (ids
//!    mapped back to `user_local` / `agent_mux`), and the host's cursor
//!    (`host/logged_seq`) past them, so nothing is logged or answered twice.
//! 4. **Deliver** like any move: restore into an empty home (this Mac or over
//!    SSH) and check the counts; into the home it left, the merged stores are
//!    written over the frozen ones. Only then is the source marked (or, for the
//!    home it left, unmarked). A failure before that turns the hosted brain on
//!    again, so the Chief keeps answering where it was.

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::migrate::{self, Manifest, MoveOptions, MoveReport, Target};
use crate::migrate_cloud::{self as cloud, Api, LOCAL_CHIEF, LOCAL_USER};

/// Messages per memory export page (the route's cap is 1000).
const EXPORT_PAGE: usize = 1000;
/// Messages per history page (the owner's cap is 200).
const HISTORY_PAGE: u64 = 200;

/// The hosted Chief a moved home points at: `cloud:<api>/<agent>`.
pub fn cloud_source(moved_to: &str) -> Option<(String, String)> {
    let rest = moved_to.strip_prefix("cloud:")?;
    let (base, chief) = rest.rsplit_once('/')?;
    chief
        .starts_with("agent_")
        .then(|| (base.to_owned(), chief.to_owned()))
}

/// What the hosted Chief holds after the move.
#[derive(Debug, Default)]
pub struct CloudCopy {
    /// Memory messages `{i, kind, text, date}`, in id order.
    pub messages: Vec<Value>,
    /// Summary nodes `{l, i, text}`.
    pub nodes: Vec<Value>,
    /// The main conversation's messages, in seq order.
    pub history: Vec<Value>,
}

/// Waits until the hosted Chief runs no turn (its brain is off): bounded.
fn wait_idle(api: &Api, chief: &str, conversation: &str, limit: Duration) -> Result<(), String> {
    let deadline = Instant::now() + limit;
    loop {
        let (status, value) = api.call(
            "GET",
            &format!("/v1/chiefs/{chief}/runs?conversation={conversation}&limit=1"),
            None,
        )?;
        if !(200..300).contains(&status) {
            return Err(format!(
                "reading the Cloud Chief's runs: HTTP {status} {}",
                cloud::error_text(&value)
            ));
        }
        let running = value["value"]["runs"]
            .as_array()
            .is_some_and(|r| r.iter().any(|x| x["status"] == "running"));
        if !running {
            return Ok(());
        }
        if Instant::now() > deadline {
            return Err("a Cloud Chief turn still runs: try again when it ends".into());
        }
        // Bounded wait for the hosted turn to end; the API has no push for a CLI.
        std::thread::sleep(Duration::from_secs(2));
    }
}

/// Reads the hosted memory and the whole main conversation.
pub fn export(api: &Api, chief: &str, conversation: &str) -> Result<CloudCopy, String> {
    let mut copy = CloudCopy::default();
    let mut after: i64 = -1;
    loop {
        let (status, value) = api.call(
            "GET",
            &format!(
                "/v1/chiefs/{chief}/memory?conversation={conversation}&export=1&after={after}&limit={EXPORT_PAGE}"
            ),
            None,
        )?;
        if value["ok"] != true {
            return Err(format!(
                "memory export: HTTP {status} {} (the service may predate the export route)",
                cloud::error_text(&value)
            ));
        }
        let page = &value["value"];
        if after < 0 {
            copy.nodes = page["nodes"].as_array().cloned().unwrap_or_default();
        }
        let messages = page["messages"].as_array().cloned().unwrap_or_default();
        let count = page["count"].as_u64().unwrap_or(0);
        let Some(last) = messages.last().and_then(|m| m["i"].as_i64()) else {
            break;
        };
        copy.messages.extend(messages);
        after = last;
        if copy.messages.len() as u64 >= count {
            break;
        }
    }
    for (k, m) in copy.messages.iter().enumerate() {
        if m["i"].as_u64() != Some(k as u64) {
            return Err(format!("memory export is not dense at {k}"));
        }
    }
    let mut before: Option<u64> = None;
    loop {
        let mut params = json!({"conversation": conversation, "limit": HISTORY_PAGE});
        if let Some(b) = before {
            params["before_seq"] = json!(b);
        }
        let page = api.read("conversation.history", params)?;
        let messages = page["messages"].as_array().cloned().unwrap_or_default();
        let oldest = messages.first().and_then(|m| m["seq"].as_u64());
        let mut older = messages;
        older.append(&mut copy.history);
        copy.history = older;
        match oldest {
            Some(seq) if page["has_more"] == true && seq > 1 => before = Some(seq),
            _ => break,
        }
    }
    Ok(copy)
}

/// Rewrites the hosted ids back to the local ones (never inside text).
fn local_ids(value: &mut Value, chief: &str) {
    match value {
        Value::String(s) if s == chief => *s = LOCAL_CHIEF.to_owned(),
        Value::String(s) if s.starts_with("user_") => *s = LOCAL_USER.to_owned(),
        Value::Array(a) => a.iter_mut().for_each(|v| local_ids(v, chief)),
        Value::Object(m) => {
            for (k, v) in m.iter_mut() {
                if k != "text" && k != "id" && k != "client_msg_id" {
                    local_ids(v, chief);
                }
            }
        }
        _ => {}
    }
}

/// What a merge added.
#[derive(Clone, Copy, Debug, Default)]
pub struct Merged {
    pub memory_added: u64,
    pub nodes_added: u64,
    pub conversation_added: u64,
}

/// Merges the hosted copy into the checkpoint at `ckpt` (taken from the frozen
/// home) and reseals its manifest.
pub fn merge(ckpt: &Path, copy: &CloudCopy, chief: &str) -> Result<Merged, String> {
    let manifest = migrate::read_manifest(ckpt)?;
    let mut merged = Merged::default();
    let memory_db = ckpt.join("files/optchat/memory.sqlite3");
    let mem = rusqlite::Connection::open(&memory_db).map_err(|e| format!("memory: {e}"))?;
    let local: u64 = mem
        .query_row("SELECT COUNT(*) FROM messages", [], |r| r.get::<_, i64>(0))
        .map_err(|e| format!("memory: {e}"))? as u64;
    if (copy.messages.len() as u64) < local {
        return Err(format!(
            "the cloud memory holds {} messages, fewer than the {local} this home had: not this Chief's copy",
            copy.messages.len()
        ));
    }
    if local > 0 {
        let last: String = mem
            .query_row(
                "SELECT text FROM messages WHERE id = ?1",
                [(local - 1) as i64],
                |r| r.get(0),
            )
            .map_err(|e| format!("memory: {e}"))?;
        if copy.messages[(local - 1) as usize]["text"].as_str() != Some(last.as_str()) {
            return Err(
                "the cloud memory does not continue this home's memory: not this Chief's copy"
                    .into(),
            );
        }
    }
    // Conversation first: its last seq goes into the host's cursor, written with the memory.
    let conv_db = manifest
        .session_dir
        .as_ref()
        .map(|d| ckpt.join("files/tui").join(d).join("conversations.sqlite3"))
        .filter(|p| p.exists());
    let mut logged_seq = None;
    if let Some(conv_db) = &conv_db {
        let imported =
            cloud::import_messages(&cloud::local_history(conv_db)?, "user_X", chief).len() as u64;
        let (added, last_seq) = merge_conversation(conv_db, copy, chief, imported)?;
        merged.conversation_added = added;
        logged_seq = last_seq;
    }
    let tx = mem.unchecked_transaction().map_err(|e| e.to_string())?;
    for m in &copy.messages[local as usize..] {
        let date = m["date"].as_str().unwrap_or_default();
        let kind = m["kind"].as_str().unwrap_or_default();
        if optchat_core::Kind::parse(kind).is_none() {
            return Err(format!("cloud memory message {} has kind {kind:?}", m["i"]));
        }
        tx.execute(
            "INSERT INTO messages (id, kind, date, day, text, conv_msg) VALUES (?1, ?2, ?3, ?4, ?5, NULL)",
            rusqlite::params![
                m["i"].as_i64().unwrap_or_default(),
                kind,
                date,
                date.get(..10).unwrap_or("1970-01-01"),
                m["text"].as_str().unwrap_or_default()
            ],
        )
        .map_err(|e| format!("memory merge: {e}"))?;
        merged.memory_added += 1;
    }
    let today = migrate::now_rfc3339();
    for n in &copy.nodes {
        let text = n["text"].as_str().unwrap_or_default();
        merged.nodes_added += tx
            .execute(
                "INSERT INTO nodes (level, idx, bytes, day, text) VALUES (?1, ?2, ?3, ?4, ?5) \
                 ON CONFLICT (level, idx) DO NOTHING",
                rusqlite::params![
                    n["l"].as_i64().unwrap_or_default(),
                    n["i"].as_i64().unwrap_or_default(),
                    text.len() as i64,
                    &today[..10],
                    text
                ],
            )
            .map_err(|e| format!("memory merge: {e}"))? as u64;
    }
    if let Some(seq) = logged_seq {
        tx.execute(
            "INSERT INTO state (key, value) VALUES ('host/logged_seq', ?1) \
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            [seq.to_string()],
        )
        .map_err(|e| format!("memory merge: {e}"))?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    drop(mem);
    reseal(ckpt, manifest)?;
    Ok(merged)
}

/// Appends the hosted conversation's messages after `imported` to the local
/// Chief conversation. Returns how many were added and its last seq.
fn merge_conversation(
    db: &Path,
    copy: &CloudCopy,
    chief: &str,
    imported: u64,
) -> Result<(u64, Option<u64>), String> {
    let conn = rusqlite::Connection::open(db).map_err(|e| format!("conversations: {e}"))?;
    let Some((conversation, mut last_seq)) = local_conversation(&conn)? else {
        return Ok((0, None));
    };
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let mut added = 0;
    for message in copy
        .history
        .iter()
        .filter(|m| m["seq"].as_u64().unwrap_or(0) > imported)
    {
        let author = message["author"].as_str().unwrap_or("");
        if author != chief && !author.starts_with("user_") {
            continue;
        }
        let id = message["id"].as_str().unwrap_or("").to_owned();
        let exists: bool = tx
            .query_row("SELECT 1 FROM message WHERE id = ?1", [&id], |_| Ok(()))
            .is_ok();
        if id.is_empty() || exists {
            continue;
        }
        let mut local = message.clone();
        local_ids(&mut local, chief);
        last_seq += 1;
        local["seq"] = json!(last_seq);
        if let Some(root) = local["thread_root"].as_str() {
            let known: bool = tx
                .query_row("SELECT 1 FROM message WHERE id = ?1", [root], |_| Ok(()))
                .is_ok();
            if !known && let Some(o) = local.as_object_mut() {
                o.remove("thread_root");
            }
        }
        tx.execute(
            "INSERT INTO message (conversation, seq, id, message_json) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![conversation, last_seq as i64, id, local.to_string()],
        )
        .map_err(|e| format!("conversation merge: {e}"))?;
        added += 1;
    }
    tx.execute(
        "UPDATE conversation SET last_seq = ?2, rev = rev + 1, updated_at = ?3 WHERE id = ?1",
        rusqlite::params![conversation, last_seq as i64, migrate::now_rfc3339()],
    )
    .map_err(|e| format!("conversation merge: {e}"))?;
    let has_cursor: bool = tx
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'read_cursor'",
            [],
            |_| Ok(()),
        )
        .is_ok();
    if has_cursor {
        tx.execute(
            "INSERT INTO read_cursor (conversation, participant, seq) VALUES (?1, ?2, ?3) \
             ON CONFLICT (conversation, participant) DO UPDATE SET seq = excluded.seq",
            rusqlite::params![conversation, LOCAL_CHIEF, last_seq as i64],
        )
        .map_err(|e| format!("conversation merge: {e}"))?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok((added, Some(last_seq)))
}

/// The local Chief conversation (`user_local` and `agent_mux` only, the most
/// messages) and its last seq.
fn local_conversation(conn: &rusqlite::Connection) -> Result<Option<(String, u64)>, String> {
    let mut stmt = conn
        .prepare("SELECT id, participants_json, last_seq FROM conversation ORDER BY last_seq DESC")
        .map_err(|e| e.to_string())?;
    let rows: Vec<(String, String, i64)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    Ok(rows.into_iter().find_map(|(id, participants, last)| {
        let p: Value = serde_json::from_str(&participants).unwrap_or(Value::Null);
        let ids: Vec<&str> = p
            .as_array()
            .map(|a| a.iter().filter_map(|x| x["id"].as_str()).collect())
            .unwrap_or_default();
        (ids.len() == 2 && ids.contains(&LOCAL_CHIEF) && ids.contains(&LOCAL_USER))
            .then_some((id, last.max(0) as u64))
    }))
}

/// Recomputes the hashes, sizes, row counts and totals of a changed checkpoint.
fn reseal(ckpt: &Path, mut manifest: Manifest) -> Result<(), String> {
    for file in &mut manifest.files {
        let path = ckpt.join("files").join(&file.path);
        let (sha, size) = migrate::sha256_file(&path)?;
        file.sha256 = sha;
        file.size = size;
        if file.tables.is_some() {
            file.tables = Some(migrate::table_counts(&path)?);
        }
    }
    let find = |p: &str| {
        manifest
            .files
            .iter()
            .find(|f| f.path == p)
            .and_then(|f| f.tables.clone())
    };
    manifest.memory = migrate::memory_counts(find("optchat/memory.sqlite3").as_ref());
    if let Some(dir) = &manifest.session_dir {
        manifest.conversations.messages = find(&format!("tui/{dir}/conversations.sqlite3"))
            .and_then(|t| t.get("message").copied())
            .unwrap_or(0);
    }
    let text = serde_json::to_string_pretty(&manifest).map_err(|e| e.to_string())?;
    migrate::write_private(&ckpt.join("manifest.json"), text.as_bytes())
}

/// Writes a checkpoint's stores over `home` (the home the Chief left, whose
/// frozen copy the checkpoint was taken from): every file of the checkpoint,
/// atomically one by one; machine-local files stay. Each SQLite store's
/// `-wal` and `-shm` go first, so no old journal replays over the new file.
pub fn restore_over(ckpt: &Path, home: &Path) -> Result<usize, String> {
    let manifest = migrate::verify_checkpoint(ckpt)?;
    let to_session = migrate::session_dir_for(home);
    let mut written = 0;
    for file in &manifest.files {
        let rel = migrate::target_rel(&file.path, manifest.session_dir.as_deref(), &to_session);
        let to = home.join(&rel);
        if let Some(dir) = to.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let part = to.with_extension("chief-return");
        std::fs::copy(ckpt.join("files").join(&file.path), &part)
            .map_err(|e| format!("restoring {rel}: {e}"))?;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&part, std::fs::Permissions::from_mode(file.mode))
            .map_err(|e| format!("{rel}: {e}"))?;
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", to.display()));
        }
        std::fs::rename(&part, &to).map_err(|e| format!("{rel}: {e}"))?;
        written += 1;
    }
    Ok(written)
}

/// Is `target` the home itself (the way back into the home the Chief left)?
fn is_home(target: &Target, home: &Path) -> bool {
    matches!(target, Target::Local(p) if std::fs::canonicalize(p).ok().as_deref() == Some(home))
}

/// Moves the Chief of `home` (moved to the hosted Chief `chief` at `base`)
/// to `options.target`. Fills `report`; on an error the hosted brain is on
/// again (unless it was off before the move began).
pub fn move_out(
    options: &MoveOptions,
    home: &Path,
    base: &str,
    chief: &str,
    report: &mut MoveReport,
) -> Result<(), String> {
    let conversation = cloud::chief_main_conversation(chief);
    report.from = format!("cloud:{base}/{chief}");
    let into_home = is_home(&options.target, home);
    let api = migrate::timed(&mut report.steps, "preflight", || {
        if let Target::Local(p) = &options.target
            && !into_home
            && !migrate::absent_or_empty(p)
        {
            return Err(format!("{} is not empty", p.display()));
        }
        let token = cloud::session_token(options.session_token_file.as_deref(), Some(base))?;
        let api = Api::new(base.to_owned(), token);
        let on = api.brain(chief)?;
        Ok((
            api,
            format!(
                "{base}: the Cloud Chief {chief} is there (brain {})",
                if on == Some(true) { "on" } else { "off" }
            ),
        ))
    })?;
    if let Target::Ssh { host, .. } = &options.target {
        migrate::timed(&mut report.steps, "preflight target", || {
            let bin = migrate::remote_mover(host, &options.remote_bin)?;
            Ok(((), format!("{host} has {bin}")))
        })?;
    }
    if options.dry_run {
        return Ok(());
    }
    let was_on = api.brain(chief)? == Some(true);
    migrate::timed(&mut report.steps, "freeze", || {
        api.set_brain(chief, false)?;
        wait_idle(&api, chief, &conversation, options.drain_timeout)?;
        Ok(((), "the Cloud Chief's brain is off and no turn runs".into()))
    })?;
    let thaw = |e: String| -> String {
        if was_on && let Err(back) = api.set_brain(chief, true) {
            return format!("{e}; and turning the Cloud Chief back on failed: {back}");
        }
        e
    };
    let parent = home.parent().unwrap_or(Path::new("/tmp"));
    let tmp = parent.join(format!(".chief-return-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let built = migrate::timed(&mut report.steps, "export+merge", || {
        let copy = export(&api, chief, &conversation)?;
        migrate::checkpoint(
            home,
            &tmp,
            &migrate::CheckpointOptions {
                without_transcripts: options.without_transcripts,
                live: false,
            },
        )?;
        let m = merge(&tmp, &copy, chief)?;
        let manifest = migrate::verify_checkpoint(&tmp)?;
        let detail = format!(
            "{} memory messages (+{}), {} nodes added, {} conversation messages (+{})",
            manifest.memory.messages,
            m.memory_added,
            m.nodes_added,
            manifest.conversations.messages,
            m.conversation_added
        );
        Ok((manifest, detail))
    });
    let manifest = match built {
        Ok(m) => m,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(thaw(e));
        }
    };
    report.memory = manifest.memory.clone();
    report.conversations = manifest.conversations.clone();
    report.bytes = manifest.files.iter().map(|f| f.size).sum();
    let sha = migrate::manifest_sha(&tmp).unwrap_or_default();
    let delivered = if into_home {
        migrate::timed(&mut report.steps, "restore+verify", || {
            let n = restore_over(&tmp, home)?;
            let v = migrate::verify_home(home)?;
            if v.memory.messages != manifest.memory.messages
                || v.conversations != manifest.conversations
            {
                return Err(format!("the home reads different counts: {v:?}"));
            }
            Ok((
                home.to_string_lossy().into_owned(),
                format!("wrote {n} files over {}", home.display()),
            ))
        })
    } else {
        migrate::deliver(options, &tmp, &manifest, report, None)
    };
    let _ = std::fs::remove_dir_all(&tmp);
    let to = match delivered {
        Ok(to) => to,
        Err(e) => return Err(thaw(e)),
    };
    migrate::timed(&mut report.steps, "commit", || {
        if into_home {
            std::fs::remove_file(home.join(migrate::MOVED_FILE)).map_err(|e| e.to_string())?;
            let _ = std::fs::remove_file(home.join(migrate::SHUTDOWN_FILE));
            Ok((
                (),
                format!(
                    "{} answers again; the Cloud Chief stays off",
                    home.display()
                ),
            ))
        } else {
            migrate::mark_moved(home, &to, &sha)?;
            Ok((
                (),
                format!("source marked moved to {to}; the Cloud Chief stays off"),
            ))
        }
    })
    .map_err(thaw)?;
    report.to = if into_home {
        format!("local:{}", home.display())
    } else {
        to
    };
    report.moved = true;
    Ok(())
}

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
/// The largest text file whose home path is rewritten (as `restore`).
const REWRITE_LIMIT: u64 = 4 << 20;
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
    let old_root = manifest.source.root.as_str();
    let new_root = home.to_string_lossy();
    let mut written = 0;
    for file in &manifest.files {
        let rel = migrate::target_rel(&file.path, manifest.session_dir.as_deref(), &to_session);
        let to = home.join(&rel);
        if let Some(dir) = to.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let part = to.with_extension("chief-return");
        let from = ckpt.join("files").join(&file.path);
        let text_file = [".json", ".toml", ".md"].iter().any(|e| rel.ends_with(e))
            && file.size <= REWRITE_LIMIT;
        let text = if text_file {
            std::fs::read_to_string(&from).ok()
        } else {
            None
        };
        match text.filter(|t| !old_root.is_empty() && old_root != new_root && t.contains(old_root))
        {
            // A preset or setting that names the old machine's home names this one (as `restore`).
            Some(t) => std::fs::write(&part, t.replace(old_root, &new_root)),
            None => std::fs::copy(&from, &part).map(|_| ()),
        }
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

/// A teleport the Cloud Chief asked for (its `teleport` tool): the brain
/// config's `teleport` field, `{to, id, at}`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub to: String,
    pub id: String,
}

/// The pending request in a `GET /v1/chiefs/<id>/brain` answer, if any.
pub fn request_of(brain: &Value) -> Option<Request> {
    let t = &brain["value"]["config"]["teleport"];
    Some(Request {
        to: t["to"].as_str()?.to_owned(),
        id: t["id"].as_str()?.to_owned(),
    })
}

/// The move target of a request: `home` is the home the Chief left.
pub fn request_target(to: &str, home: &Path) -> Result<Target, String> {
    match to {
        "home" | "this-mac" | "laptop" => Ok(Target::Local(home.to_path_buf())),
        t if t.starts_with("ssh:") || t.starts_with("local:") => Target::parse(t),
        t => Err(format!(
            "the Cloud Chief asked for {t:?}: use home or ssh:HOST"
        )),
    }
}

/// The file a Chief that moved in from another machine writes to ask that
/// machine to move it (the MCP `move` tool there): `{to, id, at}`.
pub const REQUEST_FILE: &str = "state/teleport-request.json";

/// The home a Chief moved to over SSH: `ssh:HOST:PATH`.
pub fn ssh_source(moved_to: &str) -> Option<(String, String)> {
    let rest = moved_to.strip_prefix("ssh:")?;
    let (host, path) = rest.split_once(':')?;
    Some((host.to_owned(), path.to_owned()))
}

/// `optchat-chief move watch`: while `home` is moved away (to a Cloud Chief or
/// over SSH), waits for that Chief's teleport request and carries it out. The
/// Mac that holds the frozen copy runs every move out of it: it has the copy,
/// the SSH keys and the app's sign-in. Returns when the home answers here again.
/// One watcher per home.
pub fn watch(home: &Path, template: &MoveOptions, every: Duration) -> Result<String, String> {
    let lock_path = home.join("state").join("move-watch.lock");
    let _lock = crate::lock::HostLock::take(&lock_path, migrate::now_millis() as u64)
        .map_err(|e| format!("another watcher runs for {}: {e:?}", home.display()))?;
    let mut done: Option<String> = None;
    loop {
        let Some(m) = migrate::moved(home) else {
            return Ok(format!("{} answers here", home.display()));
        };
        match poll_once(home, template, &m.to, &mut done) {
            Ok(Some(line)) => eprintln!("optchat-chief move watch: {line}"),
            Ok(None) => {}
            Err(e) => eprintln!("optchat-chief move watch: {e}"),
        }
        if migrate::moved(home).is_none() {
            return Ok(format!("{} answers here again", home.display()));
        }
        // Bounded interval between looks at where the Chief is now; neither the
        // cloud API nor SSH pushes to a process on this Mac.
        std::thread::sleep(every);
    }
}

/// The pending request of the Chief at `moved_to`, if any, and how to clear it.
/// Clears a request once it is taken.
type Clear = Box<dyn Fn()>;

fn pending(template: &MoveOptions, moved_to: &str) -> Result<Option<(Request, Clear)>, String> {
    if let Some((base, chief)) = cloud_source(moved_to) {
        let token = cloud::session_token(template.session_token_file.as_deref(), Some(&base))?;
        let api = Api::new(base.clone(), token);
        let (status, value) = api.call("GET", &format!("/v1/chiefs/{chief}/brain"), None)?;
        if !(200..300).contains(&status) {
            return Err(format!("reading the Cloud Chief: HTTP {status}"));
        }
        return Ok(request_of(&value).map(|r| {
            let clear: Clear = Box::new(move || {
                let _ = api.call(
                    "PUT",
                    &format!("/v1/chiefs/{chief}/brain"),
                    Some(&json!({"teleport": null})),
                );
            });
            (r, clear)
        }));
    }
    if let Some((host, path)) = ssh_source(moved_to) {
        let file = format!("{path}/{REQUEST_FILE}");
        let out = migrate::ssh(
            &host,
            &format!("cat {} 2>/dev/null || true", migrate::sh_quote(&file)),
            None,
        )?;
        let value: Value = serde_json::from_str(out.trim()).unwrap_or(Value::Null);
        let request = match (value["to"].as_str(), value["id"].as_str()) {
            (Some(to), Some(id)) => Request {
                to: to.to_owned(),
                id: id.to_owned(),
            },
            _ => return Ok(None),
        };
        let clear: Clear = Box::new(move || {
            let _ = migrate::ssh(&host, &format!("rm -f {}", migrate::sh_quote(&file)), None);
        });
        return Ok(Some((request, clear)));
    }
    Ok(None)
}

/// One look at where the Chief is; a new request runs the move and is
/// cleared (also when the move failed: `state/move.json` says why).
fn poll_once(
    home: &Path,
    template: &MoveOptions,
    moved_to: &str,
    done: &mut Option<String>,
) -> Result<Option<String>, String> {
    let Some((request, clear)) = pending(template, moved_to)? else {
        return Ok(None);
    };
    if done.as_deref() == Some(request.id.as_str()) {
        return Ok(None);
    }
    *done = Some(request.id.clone());
    let target = request_target(&request.to, home);
    clear();
    let mut options = template.clone();
    options.home = home.to_path_buf();
    options.dry_run = false;
    options.stop_host = true;
    let report = match target {
        Err(e) => return Err(e),
        Ok(target) => {
            options.target = target;
            teleport(&options)
        }
    };
    let _ = migrate::write_private(
        &home.join("state").join("move.json"),
        serde_json::to_string(&report)
            .unwrap_or_default()
            .as_bytes(),
    );
    match report.error {
        None => Ok(Some(format!(
            "moved to {} (request {})",
            report.to, request.id
        ))),
        Some(e) => Err(format!("teleport to {} failed: {e}", request.to)),
    }
}

/// A move from wherever the Chief of `options.home` is now: out of the
/// cloud directly; out of an SSH host by first bringing it back here, then on
/// to the target when that is not this home.
pub fn teleport(options: &MoveOptions) -> MoveReport {
    let home = std::fs::canonicalize(&options.home).unwrap_or_else(|_| options.home.clone());
    let moved_to = migrate::moved(&home).map(|m| m.to);
    let Some((host, path)) = moved_to.as_deref().and_then(ssh_source) else {
        return migrate::move_chief(options);
    };
    let mut back = options.clone();
    back.target = Target::Local(home.clone());
    let mut report = pull_back(&back, &home, &host, &path);
    if report.error.is_some() || is_home(&options.target, &home) {
        return report;
    }
    let onward = migrate::move_chief(options);
    report.steps.extend(onward.steps);
    report.to = onward.to;
    report.moved = onward.moved;
    report.error = onward.error;
    report.memory = onward.memory;
    report.conversations = onward.conversations;
    report.cloud = onward.cloud;
    report
}

/// Brings the Chief that moved to `host:path` back into `home` (the home it
/// left): freeze it there (host stopped, start held), checkpoint, copy back,
/// write over the frozen copy here, check, then retire the remote home.
pub fn pull_back(options: &MoveOptions, home: &Path, host: &str, path: &str) -> MoveReport {
    let mut report = MoveReport {
        from: format!("ssh:{host}:{path}"),
        to: format!("local:{}", home.display()),
        moved: false,
        dry_run: options.dry_run,
        steps: Vec::new(),
        memory: migrate::Counts::default(),
        conversations: migrate::Counts::default(),
        bytes: 0,
        error: None,
        cloud: None,
    };
    if let Err(e) = pull_back_steps(options, home, host, path, &mut report) {
        report.error = Some(e);
    }
    report
}

fn pull_back_steps(
    options: &MoveOptions,
    home: &Path,
    host: &str,
    path: &str,
    report: &mut MoveReport,
) -> Result<(), String> {
    let q = migrate::sh_quote;
    let bin = migrate::timed(&mut report.steps, "preflight", || {
        let bin = migrate::remote_mover(host, &options.remote_bin)?;
        let detail = format!("{host} has {bin}");
        Ok((bin, detail))
    })?;
    if options.dry_run {
        return Ok(());
    }
    let stage = format!("{path}.return");
    migrate::timed(&mut report.steps, "freeze", || {
        let out = migrate::ssh(
            host,
            &format!("{} move freeze --home {}", q(&bin), q(path)),
            None,
        )?;
        Ok(((), out.trim().to_owned()))
    })?;
    let thaw = |e: String| -> String {
        let _ = migrate::ssh(
            host,
            &format!(
                "{} move thaw --home {}; rm -rf {}",
                q(&bin),
                q(path),
                q(&stage)
            ),
            None,
        );
        e
    };
    let parent = home.parent().unwrap_or(Path::new("/tmp"));
    let tmp = parent.join(format!(".chief-pull-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let fetched = migrate::timed(&mut report.steps, "checkpoint+transfer", || {
        migrate::ssh(
            host,
            &format!(
                "rm -rf {s} && {b} move checkpoint --home {p} --out {s}",
                s = q(&stage),
                b = q(&bin),
                p = q(path)
            ),
            None,
        )?;
        migrate::create_private_dir(&tmp)?;
        ssh_tar_out(host, &stage, &tmp)?;
        let m = migrate::verify_checkpoint(&tmp)?;
        let detail = format!(
            "{} memory messages, {} conversation messages",
            m.memory.messages, m.conversations.messages
        );
        Ok((m, detail))
    });
    let manifest = match fetched {
        Ok(m) => m,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(thaw(e));
        }
    };
    report.memory = manifest.memory.clone();
    report.conversations = manifest.conversations.clone();
    report.bytes = manifest.files.iter().map(|f| f.size).sum();
    let restored = migrate::timed(&mut report.steps, "restore+verify", || {
        let n = restore_over(&tmp, home)?;
        let v = migrate::verify_home(home)?;
        if v.memory.messages != manifest.memory.messages
            || v.conversations != manifest.conversations
        {
            return Err(format!("this home reads different counts: {v:?}"));
        }
        Ok(((), format!("wrote {n} files over {}", home.display())))
    });
    let _ = std::fs::remove_dir_all(&tmp);
    restored.map_err(thaw)?;
    let here = format!("local:{}", home.display());
    let back = migrate::timed(&mut report.steps, "commit", || {
        migrate::ssh(
            host,
            &format!(
                "{b} move retire --home {p} --to {t}; rm -rf {s}",
                b = q(&bin),
                p = q(path),
                t = q(&here),
                s = q(&stage)
            ),
            None,
        )?;
        // The subagents a move handed to that host come back with the Chief, while its host
        // here still does not start (the marker is there), so their new place is the only
        // write. The Chief is home either way; one that does not come back stays on record.
        let back = crate::migrate_subagents::recorded(home)
            .map(|_| crate::migrate_subagents::bring_back(home));
        std::fs::remove_file(home.join(migrate::MOVED_FILE)).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(home.join(migrate::SHUTDOWN_FILE));
        Ok((
            back,
            format!("{} answers again; {host}:{path} is retired", home.display()),
        ))
    })?;
    report.moved = true;
    if let Some(back) = back {
        let _ = migrate::timed(&mut report.steps, "subagents", || back.map(|d| ((), d)));
    }
    Ok(())
}

/// Copies the remote directory `remote` into the empty local `local` (tar over SSH).
fn ssh_tar_out(host: &str, remote: &str, local: &Path) -> Result<(), String> {
    use std::process::{Command, Stdio};
    let ssh_bin = crate::cli::env("OPTCHAT_MOVE_SSH").unwrap_or_else(|| "ssh".into());
    let mut sender = Command::new(ssh_bin)
        .args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host])
        .arg(format!("tar -C {} -cf - .", migrate::sh_quote(remote)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("ssh {host}: {e}"))?;
    let pipe = sender.stdout.take().ok_or("ssh gave no output pipe")?;
    let unpack = Command::new("tar")
        .arg("-C")
        .arg(local)
        .args(["-xf", "-"])
        .stdin(Stdio::from(pipe))
        .output()
        .map_err(|e| format!("tar: {e}"))?;
    let sent = sender
        .wait_with_output()
        .map_err(|e| format!("ssh {host}: {e}"))?;
    if !sent.status.success() {
        return Err(format!(
            "ssh {host} tar failed: {}",
            String::from_utf8_lossy(&sent.stderr).trim()
        ));
    }
    if !unpack.status.success() {
        return Err(format!(
            "tar: {}",
            String::from_utf8_lossy(&unpack.stderr).trim()
        ));
    }
    Ok(())
}

/// The machine a Chief moved in from, when that is another machine: its
/// `state/moved-in.json` host. None for a Chief that started here.
pub fn origin(home: &Path) -> Option<String> {
    let text = std::fs::read_to_string(home.join(migrate::MOVED_IN_FILE)).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let host = v["from_host"].as_str()?.to_owned();
    (host != migrate::hostname() && !host.is_empty()).then_some(host)
}

/// Writes this home's teleport request for the machine it moved in from,
/// whose watcher carries it out after this turn.
pub fn ask_origin(home: &Path, origin: &str, to: &str) -> Result<String, String> {
    let id = format!("tp-{}", migrate::now_millis());
    let request = json!({"to": to, "id": id, "at": migrate::now_rfc3339()});
    migrate::create_private_dir(&home.join("state"))?;
    migrate::write_private(&home.join(REQUEST_FILE), request.to_string().as_bytes())?;
    Ok(json!({
        "scheduled": true,
        "request": id,
        "by": origin,
        "note": format!("{origin} moves you to {to} within about a minute; answer the person now and say goodbye: your next answer comes from there"),
    })
    .to_string())
}

//! `acpmux session move HOST/CHAT --machine TARGET --from-snapshot`: starts a chat on `TARGET`
//! from this machine's copy of it (`hub/peer_snapshot.rs`, `_acpmux/peer_snapshot`), for a chat
//! whose machine does not answer (fleet-dogfoods-remote, class 4: "Copy each chat's journal to a
//! second place and let a move start from the copy").
//!
//! A move from a live machine freezes the chat there first (`transfer_begin`) and pages its whole
//! bundle across. A dead machine answers nothing, so this move pages a bundle made here instead:
//! the chat's row (its name, harness, folder, title, agent session) and the records the copy holds
//! (its newest [`SESSION_EVENTS`], oldest first), through the same `transfer_receive`,
//! `transfer_write` and `transfer_finish` as any move. Its agent's own store stayed on the dead
//! machine, so its next turn there starts a new agent session that reads the transcript
//! (`hub/lifecycle.rs`, `rehydrate`).
//!
//! The chat gets a new id there: nothing on the dead machine is closed or told (it answers
//! nothing), so when it comes back it still has its own copy, and the two never share an id. The
//! folder is `--cwd` on the target, else the path the row names.

use super::*;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

/// The most records a copy keeps, and so the most this asks for (`peer_snapshot::SESSION_EVENTS`).
const SESSION_EVENTS: u64 = 1000;
/// Bytes asked of the copy: past every copy's bound (`peer_snapshot::SESSION_BYTES`); the daemon
/// caps it at its own page bound.
const SNAPSHOT_BYTES: u64 = 64 << 20;
/// Bytes per `transfer_write`, under its page bound (`transfer_out::MAX_PAGE`).
const WRITE_PAGE: usize = 1 << 20;
/// The move schema a plain (not `cmux-harness`) chat's bundle goes under.
const TRANSFER_SCHEMA: &str = "acpmux.transfer.v1";

/// A bundle made from a copy: its files (relative path, bytes) and the manifest
/// `transfer_receive` takes.
#[derive(Debug)]
pub(crate) struct SnapshotBundle {
    pub files: Vec<(String, Vec<u8>)>,
    pub manifest: Value,
    /// Records carried, and the first seq among them.
    pub records: usize,
    pub first_seq: Option<u64>,
    /// The copy holds no older records than these (`hasMore` false).
    pub whole: bool,
}

/// The chat as `HOST/ID`: a qualified key as is, else under `--from HOST`.
pub(crate) fn qualified(key: &str, from: Option<&str>) -> Result<String> {
    if key.contains('/') {
        return Ok(key.to_owned());
    }
    match from {
        Some(host) => Ok(format!("{host}/{key}")),
        None => bail!("name the chat as MACHINE/CHAT, or pass --from MACHINE"),
    }
}

/// The bundle for chat `new_id` made from `snapshot` (a `_acpmux/peer_snapshot` reply), in
/// `cwd` when given (else the folder its row names), stamped `now` (ms).
pub(crate) fn bundle_from_snapshot(
    snapshot: &Value,
    new_id: &str,
    cwd: Option<&str>,
    now: u64,
) -> Result<SnapshotBundle> {
    let row = snapshot.get("summary").filter(|r| r.is_object()).ok_or_else(|| {
        anyhow!("this machine keeps no row of the chat: it was never listed here")
    })?;
    let text = |k: &str| row.get(k).and_then(Value::as_str).filter(|s| !s.is_empty());
    let harness = text("harness")
        .or_else(|| text("agent"))
        .ok_or_else(|| anyhow!("the kept row names no harness"))?;
    let cwd = cwd
        .or_else(|| text("cwd"))
        .ok_or_else(|| anyhow!("the kept row names no folder: pass --cwd"))?;
    let mut records: Vec<crate::store::EventRecord> = snapshot
        .get("events")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| serde_json::from_value(r.clone()).ok())
        .filter(|r: &crate::store::EventRecord| r.seq > 0)
        .collect();
    records.sort_by_key(|r| r.seq);
    records.dedup_by_key(|r| r.seq);
    let last_seq = records.last().map_or(0, |r| r.seq);
    let mut kept = json!({
        "schema": crate::store::META_SCHEMA,
        "id": new_id,
        "name": text("name").unwrap_or(new_id),
        "nameGiven": row.get("nameGiven").and_then(Value::as_bool).unwrap_or(false),
        "harness": harness,
        "cwd": cwd,
        "status": "idle",
        "createdAt": now,
        "updatedAt": now,
        "lastSeq": last_seq,
        "transcriptSeq": last_seq,
        "eventCount": records.len(),
    });
    // What the row says that the chat keeps: its agent session (gone with the machine, so its
    // next start reads the transcript instead), its title and counts.
    for k in ["family", "agentSessionId", "title", "titleSource", "lastPrompt", "preview"] {
        if let Some(v) = text(k) {
            kept[k] = json!(v);
        }
    }
    if let Some(n) = row.get("turnCount").and_then(Value::as_u64) {
        kept["turnCount"] = json!(n);
    }
    let session_json = serde_json::to_vec_pretty(&kept)?;
    // The kept meta must be one the target reads back.
    serde_json::from_slice::<crate::store::SessionMeta>(&session_json)
        .context("the kept row makes no chat")?;
    let mut events = Vec::new();
    for r in &records {
        serde_json::to_writer(&mut events, r)?;
        events.push(b'\n');
    }
    let bundle_manifest = serde_json::to_vec_pretty(&json!({
        "schema": "acpmux.bundle.v1", "id": new_id, "eventCount": records.len(),
        "lastSeq": last_seq, "native": [], "harness": null,
        "fromSnapshot": {"sessionId": snapshot.get("qualifiedSessionId"),
                         "capturedAt": snapshot.get("capturedAt")},
    }))?;
    let files = vec![
        ("session.json".to_owned(), session_json),
        ("events/000001.ndjson".to_owned(), events),
        ("manifest.json".to_owned(), bundle_manifest),
    ];
    let listed: Vec<Value> =
        files.iter().map(|(p, b)| json!({"path": p, "size": b.len() as u64})).collect();
    let manifest = json!({
        "schema": TRANSFER_SCHEMA,
        "transferId": uuid::Uuid::now_v7().to_string(),
        "sessionId": new_id,
        "files": listed,
        "session": {"sessionId": new_id, "name": kept["name"], "harness": harness, "cwd": cwd},
    });
    Ok(SnapshotBundle {
        files,
        manifest,
        records: records.len(),
        first_seq: records.first().map(|r| r.seq),
        whole: snapshot.get("hasMore") == Some(&Value::Bool(false)),
    })
}

/// Pages `bundle` into a receive on `dst` and finishes it there: the chat's summary there.
pub(crate) async fn send_bundle(
    dst: &Client,
    bundle: &SnapshotBundle,
    from: Value,
) -> Result<Value> {
    let receive =
        dst.request("_acpmux/transfer_receive", json!({"manifest": bundle.manifest})).await?;
    let receive_id = receive.get("receiveId").cloned().unwrap_or(Value::Null);
    for (path, bytes) in &bundle.files {
        let mut offset = 0usize;
        // An empty file is written too, so the receive holds every file it lists.
        loop {
            let end = (offset + WRITE_PAGE).min(bytes.len());
            let data = BASE64.encode(&bytes[offset..end]);
            let write = json!({"receiveId": receive_id, "path": path, "offset": offset,
                               "data": data, "epoch": 0});
            dst.request("_acpmux/transfer_write", write).await?;
            offset = end;
            if offset >= bytes.len() {
                break;
            }
        }
    }
    let finish = json!({"receiveId": receive_id, "from": from, "epoch": 0});
    dst.request("_acpmux/transfer_finish", finish).await
}

/// `session move --from-snapshot`: each chat in `args` started on the target from this
/// machine's copy.
pub(crate) async fn run(args: MoveArgs, json_out: bool) -> Result<()> {
    let local = connect(true).await?;
    let peers = local.request("_acpmux/peers", json!({})).await?;
    let here = crate::pairing::machine_name();
    let to_here = names_here(&args.host, &here);
    let here_target = to_here
        .then(|| {
            Ok::<_, anyhow::Error>(Target {
                name: here.clone(),
                ssh: String::new(),
                probed: Some(local_daemon()?),
            })
        })
        .transpose()?;
    let mut targets = Targets::with_here(&args.host, &peers, here_target)?;
    let mut rows = Vec::new();
    let mut failed = 0;
    for key in &args.sessions {
        let row = match one(&local, &peers, key, &args, &mut targets).await {
            Ok(row) => row,
            Err(e) => {
                failed += 1;
                json!({"sessionId": key, "moved": false, "error": format!("{e:#}")})
            }
        };
        if !json_out {
            print_row(&row);
        }
        rows.push(row);
    }
    if json_out {
        print_json(&json!({"moves": rows, "failed": failed}));
    }
    if failed > 0 {
        bail!("{failed} of {} chats did not move", rows.len());
    }
    Ok(())
}

fn print_row(row: &Value) {
    let s = |k: &str| row.get(k).and_then(Value::as_str).unwrap_or("?");
    match row.get("error").and_then(Value::as_str) {
        Some(e) => eprintln!("{}: not moved: {e}", s("sessionId")),
        None => {
            let older = if row["whole"] == true {
                String::new()
            } else {
                format!("; records before seq {} were not kept here", row["firstSeq"])
            };
            println!(
                "{} ({}): started on {} as {} in {} from this machine's copy: {} records{older}",
                s("name"),
                s("sessionId"),
                s("host"),
                s("targetSessionId"),
                s("cwd"),
                row["records"],
            );
        }
    }
}

async fn one(
    local: &std::sync::Arc<Client>,
    peers: &Value,
    key: &str,
    args: &MoveArgs,
    targets: &mut Targets,
) -> Result<Value> {
    let qualified = qualified(key, args.from.as_deref())?;
    let source = qualified.split('/').next().unwrap_or_default().to_owned();
    if targets.named.as_deref().is_some_and(|n| n.eq_ignore_ascii_case(&source)) {
        bail!("the chat is on {source}: name another machine");
    }
    if let Some(peer) =
        peers.get("peers").and_then(Value::as_array).into_iter().flatten().find(|p| {
            p.get("name").and_then(Value::as_str).is_some_and(|n| n.eq_ignore_ascii_case(&source))
        })
        && peer.get("connected").and_then(Value::as_bool) == Some(true)
    {
        eprintln!(
            "move: {source} answers this machine; a move from the copy leaves its chat there as it \
             is (`session move {key} --from {source}` moves the chat itself)"
        );
    }
    let snapshot = local
        .request(
            "_acpmux/peer_snapshot",
            json!({"sessionId": qualified, "limit": SESSION_EVENTS, "maxBytes": SNAPSHOT_BYTES}),
        )
        .await?;
    let new_id = uuid::Uuid::now_v7().to_string();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    let bundle = bundle_from_snapshot(&snapshot, &new_id, args.cwd.as_deref(), now)?;
    let name = bundle.manifest["session"]["name"].as_str().unwrap_or(&new_id).to_owned();
    let group = PathBuf::from(bundle.manifest["session"]["cwd"].as_str().unwrap_or_default());
    let target = targets.pick(local, &group, 0).await?;
    let cwd = bundle.manifest["session"]["cwd"].clone();
    let mut row = json!({"sessionId": qualified, "name": name, "host": target.name, "cwd": cwd,
                         "records": bundle.records, "firstSeq": bundle.first_seq,
                         "whole": bundle.whole, "moved": false, "fromSnapshot": true});
    if args.dry_run {
        row["dryRun"] = json!(true);
        return Ok(row);
    }
    let remote = match target.probed.clone() {
        Some(r) => r,
        None => target.remote().await?,
    };
    let (forward, dst) = if target.ssh.is_empty() {
        (None, Client::connect(Path::new(&remote.socket)).await?)
    } else {
        let forward = Forward::open(&target.ssh, &remote.socket).await?;
        let dst = Client::connect(&forward.local).await?;
        (Some(forward), dst)
    };
    dst.request(
        method::INITIALIZE,
        json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-move"}}),
    )
    .await?;
    let from = json!({"sessionId": qualified, "snapshot": true,
                      "capturedAt": snapshot.get("capturedAt")});
    let sent = send_bundle(&dst, &bundle, from).await;
    if let Some(forward) = forward {
        forward.close().await;
    }
    let moved = sent?;
    row["moved"] = json!(true);
    row["targetSessionId"] = moved.get("sessionId").cloned().unwrap_or(json!(new_id));
    if let Some(n) = moved.get("name") {
        row["name"] = n.clone();
    }
    Ok(row)
}

#[cfg(test)]
#[path = "session_move_snapshot_tests.rs"]
mod tests;

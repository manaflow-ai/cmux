//! The Chief's working subagents go with it (plans/cmux-next/chief-migration-DESIGN.md 4b).
//!
//! A Chief's subagents are chats in its own acpmux daemon (`<home>/acpmux`). Their history
//! travels in the checkpoint, but a chat that is working (a running turn or queued prompts)
//! also needs its agent's own store, its folder and one writer on the new machine. That is
//! acpmux's `session move` (the agent-session-teleport skill), so a move to an SSH host hands
//! each working subagent on this Mac to it before the checkpoint:
//! `acpmux session move ID... --machine PEER --interrupt --json`. A stopped turn's continuation
//! runs there. The moved chats are recorded in `state/subagents-moved.json` (machine-local),
//! so a failed move, a rollback and a pull back bring them here again with
//! `--from PEER --machine local`. Idle and closed chats stay: their history already moved.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Where the chats a move handed over are recorded, under the home.
pub(crate) const RECORD: &str = "state/subagents-moved.json";

/// The chats one move handed to `peer`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Handed {
    pub peer: String,
    pub ids: Vec<String>,
}

/// The acpmux CLI: `OPTCHAT_MOVE_ACPMUX` (tests), else `ACPMUX_BIN`, else the one next to this
/// binary (the app bundle's `bin/`), else `acpmux` on `PATH`.
fn bin() -> PathBuf {
    if let Some(p) =
        crate::cli::env("OPTCHAT_MOVE_ACPMUX").or_else(|| crate::cli::env("ACPMUX_BIN"))
    {
        return p.into();
    }
    std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(|d| d.join("acpmux")))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| "acpmux".into())
}

/// Runs the acpmux CLI against the Chief's own daemon (`ACPMUX_HOME=<home>/acpmux`; the CLI
/// derives its socket by the shared rule) and parses its JSON answer.
fn acpmux(home: &Path, args: &[&str]) -> Result<Value, String> {
    let out = Command::new(bin())
        .args(args)
        .env("ACPMUX_HOME", home.join("acpmux"))
        .env_remove("ACPMUX_SOCKET")
        .output()
        .map_err(|e| format!("acpmux {}: {e}", args.join(" ")))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let value: Value = serde_json::from_str(text.trim()).unwrap_or(Value::Null);
    if !out.status.success() && value.is_null() {
        let err = String::from_utf8_lossy(&out.stderr);
        let last = err
            .lines()
            .rfind(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim();
        return Err(format!(
            "acpmux {}: {last}",
            args.first().copied().unwrap_or("")
        ));
    }
    Ok(value)
}

/// Whether the Chief's daemon has its socket (it runs): one that does not runs no turn, and
/// listing it would start one.
fn daemon_runs(home: &Path) -> bool {
    let acpmux = home.join("acpmux");
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let socket = crate::acpmux_daemon::socket_path_for(None, acpmux.to_str(), &user, uid);
    socket.exists() || acpmux.join("acpmux.sock").exists()
}

/// Whether a chat row is a subagent working on this machine: run here (`local/…`), not closed,
/// and with a turn running or prompts queued.
fn working_here(row: &Value) -> bool {
    let local = row["qualifiedSessionId"]
        .as_str()
        .is_some_and(|q| q.starts_with("local/"));
    let status = row["status"].as_str().unwrap_or("");
    let busy = !matches!(status, "idle" | "closed" | "")
        || row["turn"].is_object()
        || row["queued"].as_u64().unwrap_or(0) > 0;
    local && status != "closed" && busy
}

/// The working subagents of the Chief at `home` (ids). A home whose daemon does not run (or
/// never ran subagents) has none, and no acpmux is run for it.
pub(crate) fn working(home: &Path) -> Result<Vec<String>, String> {
    if !home.join("acpmux/sessions").is_dir() || !daemon_runs(home) {
        return Ok(Vec::new());
    }
    let listed = acpmux(home, &["ls", "--json"])?;
    Ok(listed["sessions"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter(|r| working_here(r))
        .filter_map(|r| r["sessionId"].as_str().map(str::to_owned))
        .collect())
}

/// The Chief daemon's machine for the SSH host `host`: a peer named so, or whose URL ends in it.
pub(crate) fn peer_for(home: &Path, host: &str) -> Result<String, String> {
    let machines = acpmux(home, &["machine", "ls", "--json"])?;
    let peers = machines["peers"].as_array().cloned().unwrap_or_default();
    peers
        .iter()
        .find_map(|p| {
            let name = p["name"].as_str()?;
            let url = p["url"].as_str().unwrap_or("");
            let host_of_url = url.rsplit(['@', '/']).next().unwrap_or("");
            (name.eq_ignore_ascii_case(host) || host_of_url.eq_ignore_ascii_case(host))
                .then(|| name.to_owned())
        })
        .ok_or_else(|| {
            format!(
                "{host} is not one of the Chief's acpmux machines, so its working subagents cannot \
                 go with it: run `ACPMUX_HOME={} acpmux machine add {host}`, then move again",
                home.join("acpmux").display()
            )
        })
}

/// Moves the chats `ids` from the daemon `from` (None: this Mac's Chief daemon) to `machine`,
/// stopping running turns (their continuation runs there). Returns the ids that moved, and an
/// error naming the ones that did not.
fn session_move(
    home: &Path,
    ids: &[String],
    from: Option<&str>,
    machine: &str,
) -> (Vec<String>, Option<String>) {
    let mut args: Vec<&str> = vec!["session", "move"];
    args.extend(ids.iter().map(String::as_str));
    if let Some(from) = from {
        args.extend(["--from", from]);
    }
    args.extend(["--machine", machine, "--interrupt", "--json"]);
    let answer = match acpmux(home, &args) {
        Ok(v) => v,
        Err(e) => return (Vec::new(), Some(e)),
    };
    let rows = answer["moves"].as_array().cloned().unwrap_or_default();
    let moved: Vec<String> = rows
        .iter()
        .filter(|r| r["moved"] == true && r["error"].is_null())
        .filter_map(|r| r["sessionId"].as_str().map(str::to_owned))
        .collect();
    let failed: Vec<String> = rows
        .iter()
        .filter(|r| !r["error"].is_null())
        .map(|r| {
            format!(
                "{}: {}",
                r["name"]
                    .as_str()
                    .or(r["sessionId"].as_str())
                    .unwrap_or("?"),
                r["error"].as_str().unwrap_or("not moved")
            )
        })
        .collect();
    let error = if failed.is_empty() && moved.len() == ids.len() {
        None
    } else if failed.is_empty() {
        Some(format!(
            "acpmux moved {} of {} chats",
            moved.len(),
            ids.len()
        ))
    } else {
        Some(failed.join("; "))
    };
    (moved, error)
}

/// Hands the working subagents of the Chief at `home` to the SSH host `host` and records them.
/// All or nothing: when one does not move, the ones that did come back and the error says why.
/// Returns the step's detail.
pub(crate) fn hand_over(home: &Path, host: &str) -> Result<(Option<Handed>, String), String> {
    // A Chief daemon that cannot list (no acpmux here) has no working subagent this move can
    // see: the move goes on and the report says so.
    let ids = match working(home) {
        Ok(ids) => ids,
        Err(e) => return Ok((None, format!("subagents not checked: {e}"))),
    };
    if ids.is_empty() {
        return Ok((None, "no subagent is working".into()));
    }
    let peer = peer_for(home, host)?;
    let (moved, error) = session_move(home, &ids, None, &peer);
    if let Some(e) = error {
        if !moved.is_empty() {
            let (_, back) = session_move(home, &moved, Some(&peer), "local");
            if let Some(b) = back {
                return Err(format!("{e}; bringing the moved ones back failed: {b}"));
            }
        }
        return Err(format!("working subagents did not move to {peer}: {e}"));
    }
    let handed = Handed { peer, ids: moved };
    record(home, &handed)?;
    place(home, &handed.ids, Some(&handed.peer))?;
    let detail = format!(
        "{} working subagents moved to {}",
        handed.ids.len(),
        handed.peer
    );
    Ok((Some(handed), detail))
}

fn record(home: &Path, handed: &Handed) -> Result<(), String> {
    let text = json!({"peer": handed.peer, "ids": handed.ids}).to_string();
    crate::migrate::write_private(&home.join(RECORD), text.as_bytes())
}

/// The chats a move handed over from `home`, if it recorded any.
pub(crate) fn recorded(home: &Path) -> Option<Handed> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(home.join(RECORD)).ok()?).ok()?;
    Some(Handed {
        peer: v["peer"].as_str()?.to_owned(),
        ids: v["ids"]
            .as_array()?
            .iter()
            .filter_map(|i| i.as_str().map(str::to_owned))
            .collect(),
    })
}

/// Brings the subagents a move handed over from `home` back to this Mac (a failed move, a
/// rollback, a pull back). The record goes once they are back. Returns the step's detail.
pub(crate) fn bring_back(home: &Path) -> Result<String, String> {
    let Some(handed) = recorded(home) else {
        return Ok("no subagent was handed over".into());
    };
    let (moved, error) = session_move(home, &handed.ids, Some(&handed.peer), "local");
    if let Some(e) = error {
        // Keep the ones still away on record, so the next try brings them.
        let left: Vec<String> = handed
            .ids
            .iter()
            .filter(|i| !moved.contains(i))
            .cloned()
            .collect();
        record(
            home,
            &Handed {
                peer: handed.peer.clone(),
                ids: left,
            },
        )?;
        return Err(format!(
            "subagents did not come back from {}: {e}",
            handed.peer
        ));
    }
    let _ = std::fs::remove_file(home.join(RECORD));
    place(home, &moved, None)?;
    Ok(format!(
        "{} subagents came back from {}",
        moved.len(),
        handed.peer
    ))
}

/// Writes, for each of the Chief's subagents whose session is one of `sessions`, its new
/// `place` (None: the Chief's own machine) and a raised `epoch`, in the home's host state
/// (`host/spawns`), as one write. The session id stays. The host is stopped while a move runs,
/// so this is the only writer; a home with no records (or none of these sessions) is left as it is.
fn place(home: &Path, sessions: &[String], place: Option<&str>) -> Result<(), String> {
    let db = home.join("optchat/memory.sqlite3");
    if sessions.is_empty() || !db.is_file() {
        return Ok(());
    }
    let key = format!("{}spawns", crate::state::HOST_PREFIX);
    let conn = rusqlite::Connection::open(&db).map_err(|e| format!("host state: {e}"))?;
    let text: Option<String> = conn
        .query_row("SELECT value FROM state WHERE key = ?1", [&key], |r| {
            r.get(0)
        })
        .ok();
    let Some(text) = text else { return Ok(()) };
    let mut spawns: Value =
        serde_json::from_str(&text).map_err(|e| format!("host state {key}: {e}"))?;
    if !placed(&mut spawns, sessions, place) {
        return Ok(());
    }
    conn.execute(
        "UPDATE state SET value = ?1 WHERE key = ?2",
        rusqlite::params![spawns.to_string(), key],
    )
    .map_err(|e| format!("host state: {e}"))?;
    Ok(())
}

/// Sets `place` and raises `epoch` on each subagent record in `spawns` (`host/spawns`'s JSON)
/// whose `session_id` is one of `sessions`. Whether one changed.
fn placed(spawns: &mut Value, sessions: &[String], place: Option<&str>) -> bool {
    let mut changed = false;
    let records = spawns
        .as_object_mut()
        .into_iter()
        .flat_map(|m| m.values_mut());
    for sub in records.filter_map(|r| r["subs"].as_array_mut()).flatten() {
        let ours = sub["session_id"]
            .as_str()
            .is_some_and(|s| sessions.iter().any(|m| m == s));
        let Some(fields) = sub.as_object_mut().filter(|_| ours) else {
            continue;
        };
        match place {
            Some(p) => fields.insert("place".into(), json!(p)),
            None => fields.remove("place"),
        };
        let epoch = fields.get("epoch").and_then(Value::as_u64).unwrap_or(0) + 1;
        fields.insert("epoch".into(), json!(epoch));
        changed = true;
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_local_chats_that_work_are_handed_over() {
        let row = |q: &str, status: &str, queued: u64, turn: Value| json!({"qualifiedSessionId": q, "status": status, "queued": queued, "turn": turn});
        assert!(working_here(&row("local/a", "running", 0, Value::Null)));
        assert!(working_here(&row("local/a", "idle", 2, Value::Null)));
        assert!(working_here(&row("local/a", "idle", 0, json!({"id": 1}))));
        assert!(!working_here(&row("local/a", "idle", 0, Value::Null)));
        assert!(!working_here(&row("local/a", "closed", 3, Value::Null)));
        assert!(!working_here(&row("vm-1/a", "running", 0, Value::Null)));
    }

    #[test]
    fn a_handed_over_subagent_keeps_its_session_and_the_host_reads_its_new_place() {
        let mut spawns = json!({"sp1": {"subs": [
            {"id": "a1", "session_id": "s-work", "title": "worker", "status": "running"},
            {"id": "a2", "session_id": "s-idle", "status": "reported"},
        ]}});
        let ids = vec!["s-work".to_owned()];
        assert!(placed(&mut spawns, &ids, Some("mini-peer")));
        let read: std::collections::BTreeMap<String, crate::state::SpawnRecord> =
            serde_json::from_value(spawns.clone()).unwrap();
        let (a1, a2) = (&read["sp1"].subs[0], &read["sp1"].subs[1]);
        assert_eq!(a1.session_id.as_deref(), Some("s-work"));
        assert_eq!((a1.place.as_deref(), a1.epoch), (Some("mini-peer"), 1));
        assert_eq!((a2.place.as_deref(), a2.epoch), (None, 0));
        assert!(placed(&mut spawns, &ids, None));
        let read: std::collections::BTreeMap<String, crate::state::SpawnRecord> =
            serde_json::from_value(spawns).unwrap();
        assert_eq!(
            (
                read["sp1"].subs[0].place.as_deref(),
                read["sp1"].subs[0].epoch
            ),
            (None, 2)
        );
        assert!(
            !placed(&mut json!({}), &ids, None),
            "no records: nothing to write"
        );
    }
}

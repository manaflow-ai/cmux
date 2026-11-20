//! `acpmux ls` reads a down `ssh://` peer's sessions over ssh: while the peer link to a machine
//! is reconnecting or offline, its rows here are the last ones the link brought, and a hung far
//! daemon or a link stuck redialing leaves them stale for as long as it lasts (huge-blue,
//! 2026-11-20). ssh itself often still works, so each such peer is asked
//! `acpmux --json ls --machine local` over a plain ssh login, all of them at once, each bounded
//! by [`LS_DEADLINE`]; the rows it answers replace that machine's rows here, marked
//! `via: "ssh"`. A peer that does not answer in time costs one stderr line and keeps the rows
//! the link left.
//!
//! The ssh destination is the peer record's own, checked (`peer::ssh_target`), and the script is
//! acpmux's fixed text. The far `acpmux` may be off a non-login PATH: `$HOME/.local/bin/acpmux`
//! is tried first, then `acpmux`.

use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

/// How long a down peer's ssh listing may take before `ls` goes on without it.
pub(crate) const LS_DEADLINE: Duration = Duration::from_secs(8);

/// The `via` of a row read over ssh.
pub(crate) const VIA: &str = "ssh";

/// The far side's listing: this machine's sessions only, as JSON.
const SCRIPT: &str = "for a in \"$HOME/.local/bin/acpmux\" acpmux; do if command -v \"$a\" >/dev/null 2>&1; then exec \"$a\" --json ls --machine local; fi; done; echo 'acpmux: not found on this machine' >&2; exit 127";

/// The peers of a `_acpmux/status` answer's `peers` that ls reads over ssh: `ssh://` ones whose
/// link is neither connected nor degraded. (name, ssh destination) each.
pub(crate) fn down_ssh_peers(peers: &[Value]) -> Vec<(String, String)> {
    peers
        .iter()
        .filter_map(|p| {
            let name = p.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
            let url = p.get("url").and_then(Value::as_str)?;
            let state = p.get("state").and_then(Value::as_str).unwrap_or_else(|| {
                if p.get("connected") == Some(&json!(true)) { "connected" } else { "offline" }
            });
            if matches!(state, "connected" | "degraded") {
                return None;
            }
            let destination = crate::peer::ssh_target(url).ok()?.destination;
            Some((name.to_owned(), destination))
        })
        .collect()
}

/// Every down ssh peer's rows read over ssh, in parallel: (the peers that answered, their rows).
/// A peer that failed is said on stderr unless `quiet`.
pub(crate) async fn rows(peers: &[Value], quiet: bool) -> (Vec<String>, Vec<Value>) {
    let down = down_ssh_peers(peers);
    if down.is_empty() {
        return (Vec::new(), Vec::new());
    }
    let deadline = Instant::now() + LS_DEADLINE;
    let reads = down.into_iter().map(|(name, destination)| async move {
        let read = tokio::task::spawn_blocking({
            let destination = destination.clone();
            move || read(&destination, deadline)
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|r| r);
        (name, read)
    });
    let mut answered = Vec::new();
    let mut all = Vec::new();
    for (name, read) in futures_util::future::join_all(reads).await {
        match read {
            Ok(rows) => {
                all.extend(rows.into_iter().map(|row| tag(&name, row)));
                answered.push(name);
            }
            Err(why) => {
                if !quiet {
                    eprintln!(
                        "acpmux: {name}'s link is down and its sessions over ssh were not read: {why}"
                    );
                }
            }
        }
    }
    (answered, all)
}

/// One peer's listing over ssh, by `deadline`.
fn read(destination: &str, deadline: Instant) -> Result<Vec<Value>, String> {
    let argv = crate::cli::hosts::ssh_argv(destination, SCRIPT).map_err(|e| e.to_string())?;
    let mut cmd = cmux_process::Command::new("ssh");
    cmd.args(argv);
    let limit = deadline.saturating_duration_since(Instant::now());
    let done = crate::cli::owned_child::owned(&mut cmd, None, limit, "the ssh listing")
        .map_err(|e| e.to_string())?;
    if !done.status.success() {
        let stderr = String::from_utf8_lossy(&done.stderr);
        let last = stderr.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim();
        return Err(format!(
            "exited {}: {}",
            done.status.code().unwrap_or(1),
            crate::cli::output::short(last, 160)
        ));
    }
    parse(&done.stdout)
}

/// The rows of a far `acpmux --json ls` answer.
fn parse(stdout: &[u8]) -> Result<Vec<Value>, String> {
    let value: Value =
        serde_json::from_slice(stdout).map_err(|_| "the far acpmux printed no JSON".to_owned())?;
    let rows = value
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| "the far acpmux printed no sessions list".to_owned())?;
    Ok(rows
        .iter()
        .filter(|r| r.get("sessionId").and_then(Value::as_str).is_some())
        .take(crate::cli::send_relay::LS_MAX_ROWS)
        .cloned()
        .collect())
}

/// A far row as this machine names it: the peer's row, `HOST/NAME`, read over ssh.
fn tag(host: &str, row: Value) -> Value {
    let mut row = crate::hub::Hub::remote_summary(host, row);
    if let Some(fields) = row.as_object_mut() {
        fields.insert("via".into(), json!(VIA));
    }
    row
}

/// `rows` with each of `hosts`' rows replaced by `far`: the stale rows the down link left go.
/// How many rows `far` added.
pub(crate) fn replace_rows(rows: &mut Vec<Value>, hosts: &[String], far: Vec<Value>) -> usize {
    rows.retain(|r| {
        r.get("peer").and_then(Value::as_str).is_none_or(|p| !hosts.iter().any(|h| h == p))
    });
    let n = far.len();
    rows.extend(far);
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_down_ssh_peers_are_read() {
        let peers = json!([
            {"name": "a", "url": "ssh://a", "state": "reconnecting"},
            {"name": "b", "url": "ssh://me@b:2222", "state": "offline"},
            {"name": "c", "url": "ssh://c", "state": "connected"},
            {"name": "d", "url": "ssh://d", "state": "degraded"},
            {"name": "e", "url": "ws://e:1", "state": "offline"},
            {"name": "f", "url": "ssh://-oProxyCommand=x", "state": "offline"},
        ]);
        assert_eq!(
            down_ssh_peers(peers.as_array().unwrap()),
            [("a".to_owned(), "a".to_owned()), ("b".to_owned(), "me@b".to_owned())]
        );
    }

    #[test]
    fn a_far_row_is_named_on_its_host_and_replaces_the_stale_ones() {
        let far =
            parse(br#"{"sessions": [{"sessionId": "s1", "name": "lane"}, {"name": "no id"}]}"#)
                .unwrap();
        let far: Vec<Value> = far.into_iter().map(|r| tag("box", r)).collect();
        assert_eq!(far.len(), 1);
        assert_eq!(
            (&far[0]["peer"], &far[0]["name"], &far[0]["via"]),
            (&json!("box"), &json!("box/lane"), &json!("ssh"))
        );
        let mut rows = vec![
            json!({"sessionId": "here", "name": "mine"}),
            json!({"sessionId": "old", "name": "box/stale", "peer": "box"}),
            json!({"sessionId": "o", "name": "other/x", "peer": "other"}),
        ];
        assert_eq!(replace_rows(&mut rows, &["box".to_owned()], far), 1);
        let ids: Vec<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
        assert_eq!(ids, ["here", "o", "s1"]);
        assert!(parse(b"nope").is_err());
    }
}

//! `acpmux ls` reads a down `ssh://` peer's sessions over ssh: while the peer link to a machine
//! is reconnecting or offline, its rows here are the last ones the link brought, and a hung far
//! daemon or a link stuck redialing leaves them stale for as long as it lasts (huge-blue,
//! 2026-11-20). ssh itself often still works, so each such peer is asked
//! `acpmux --json ls --machine local` over a plain ssh login, all of them at once, each bounded
//! by the caller's deadline (`ls_far.rs`), [`LS_DEADLINE`] at most; the rows it answers replace
//! that machine's rows here, marked `via: "ssh"`. A peer that does not answer in time costs one stderr line and keeps the rows
//! the link left.
//!
//! The ssh destination is the peer record's own, checked (`peer::ssh_target`), and the script is
//! acpmux's fixed text. The far `acpmux` may be off a non-login PATH: `$HOME/.local/bin/acpmux`
//! is tried first, then `acpmux`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::time::Instant;

/// How long a down peer's ssh listing may take before `ls` goes on without it.
pub(crate) const LS_DEADLINE: Duration = Duration::from_secs(8);

/// The `via` of a row read over ssh.
pub(crate) const VIA: &str = "ssh";

type Listing = Result<Vec<Value>, String>;

/// A resident caller can join the read directly. Independent CLIs share the private cache file.
static READS: OnceLock<crate::single_flight::SingleFlight<PathBuf, Listing>> = OnceLock::new();

/// The far side's listing: this machine's sessions only, as JSON.
const SCRIPT: &str = "for a in \"$HOME/.local/bin/acpmux\" acpmux; do if command -v \"$a\" >/dev/null 2>&1; then exec \"$a\" --json ls --machine local; fi; done; echo 'acpmux: not found on this machine' >&2; exit 127";

/// The peers of a `_acpmux/status` answer's `peers` that ls reads over ssh: `ssh://` ones whose
/// link is neither connected nor degraded. (name, ssh destination) each.
pub(crate) fn down_ssh_peers(peers: &[Value]) -> Vec<(String, String)> {
    peers
        .iter()
        .filter_map(|p| {
            let name = p.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
            // A joined machine is carried by the hub. Its peer record may still expose the
            // address used before it joined, but a Mac client cannot necessarily dial that
            // private address. Keep the hub/carrier route instead of falling through to SSH.
            if p.get("via").and_then(Value::as_str) == Some("hub") {
                return None;
            }
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
pub(crate) async fn rows(
    socket: &Path,
    peers: &[Value],
    quiet: bool,
    deadline: Instant,
) -> (Vec<String>, Vec<Value>) {
    let deadline = deadline.min(Instant::now() + LS_DEADLINE);
    let reads = destinations(peers).into_iter().map(|(destination, names)| async move {
        let path = cache_path(socket, &destination);
        let read = READS
            .get_or_init(Default::default)
            .run(path.clone(), || async move {
                tokio::task::spawn_blocking(move || {
                    cached_read(&path, deadline, || read(&destination, deadline))
                })
                .await
                .map_err(|e| e.to_string())?
            })
            .await;
        (names, read)
    });
    let mut answered = Vec::new();
    let mut all = Vec::new();
    for (names, read) in futures_util::future::join_all(reads).await {
        match read {
            Ok(rows) => {
                for name in names {
                    all.extend(rows.iter().cloned().map(|row| tag(&name, row)));
                    answered.push(name);
                }
            }
            Err(why) if !quiet => {
                for name in names {
                    eprintln!(
                        "acpmux: {name}'s link is down and its sessions over ssh were not read: {why}"
                    );
                }
            }
            Err(_) => {}
        }
    }
    (answered, all)
}

/// The WebSocket port changes the peer route, but SSH uses only its login destination.
fn destinations(peers: &[Value]) -> BTreeMap<String, BTreeSet<String>> {
    let mut destinations = BTreeMap::<_, BTreeSet<_>>::new();
    for (name, destination) in down_ssh_peers(peers) {
        destinations.entry(destination).or_default().insert(name);
    }
    destinations
}

fn cache_path(socket: &Path, destination: &str) -> PathBuf {
    use sha2::{Digest, Sha256};
    let mut key = Sha256::new();
    for field in [Some(socket.as_os_str().to_owned()), Some(destination.into())]
        .into_iter()
        .chain(["HOME", "USERPROFILE", "SSH_AUTH_SOCK", "PATH"].map(std::env::var_os))
    {
        if let Some(field) = field {
            key.update([1]);
            key.update(field.as_encoded_bytes());
        }
        key.update([0]);
    }
    crate::config::home().join("ssh-ls-cache").join(format!("{:x}", key.finalize()))
}

// Each cache file is also its destination's lock. A killed reader releases it. A partial
// write is a cache miss. This disposable snapshot needs no fsync and has no lock-file expiry.
fn cached_read(path: &Path, deadline: Instant, read: impl FnOnce() -> Listing) -> Listing {
    use std::io::{Read, Seek};

    let Some(dir) = path.parent() else { return read() };
    let mut file = match crate::config::private_state_dir(dir)
        .and_then(|()| crate::config::private_state_rw(path))
    {
        Ok(file) => file,
        Err(_) => return read(),
    };
    loop {
        match file.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) => {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err("another ssh listing is still running".into());
                }
                std::thread::sleep(left.min(Duration::from_millis(25)));
            }
            Err(std::fs::TryLockError::Error(_)) => return read(),
        }
    }
    let mut bytes = Vec::new();
    if file.read_to_end(&mut bytes).is_ok()
        && let Ok((at, mut listing)) = serde_json::from_slice::<(u64, Listing)>(&bytes)
        && let Some(age) = crate::store::now_ms().checked_sub(at)
        && age <= if listing.is_ok() { 10_000 } else { 1_000 }
    {
        if let Ok(rows) = &mut listing {
            for row in rows {
                if let Some(fields) = row.as_object_mut() {
                    fields.insert("asOfMs".into(), json!(at));
                }
            }
        }
        return listing;
    }

    let listing = read();
    if file.rewind().is_ok() && file.set_len(0).is_ok() {
        let _ = serde_json::to_writer(
            std::io::BufWriter::new(&mut file),
            &(crate::store::now_ms(), &listing),
        );
    }
    listing
}

/// One peer's listing over ssh, by `deadline`.
fn read(destination: &str, deadline: Instant) -> Result<Vec<Value>, String> {
    let argv = crate::cli::hosts::ssh_argv(destination, SCRIPT).map_err(|e| e.to_string())?;
    let mut cmd = cmux_process::Command::new("ssh");
    cmd.args(argv);
    let limit = deadline.saturating_duration_since(Instant::now());
    if limit.is_zero() {
        return Err("the ssh listing reached its deadline".into());
    }
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
            {"name": "joined", "url": "ssh://10.0.0.8", "state": "offline", "via": "hub"},
            {"name": "e", "url": "ws://e:1", "state": "offline"},
            {"name": "f", "url": "ssh://-oProxyCommand=x", "state": "offline"},
        ]);
        assert_eq!(
            down_ssh_peers(peers.as_array().unwrap()),
            [("a".to_owned(), "a".to_owned()), ("b".to_owned(), "me@b".to_owned())]
        );
    }

    #[test]
    fn ssh_listing_reads_once_per_destination_and_keeps_aliases_and_users_separate() {
        let peers = json!([
            {"name":"a","url":"ssh://u@host:1"}, {"name":"b","url":"ssh://u@host:2"},
            {"name":"a","url":"ssh://u@host:1"}, {"name":"c","url":"ssh://v@host"},
        ]);
        let groups = destinations(peers.as_array().unwrap());
        assert_eq!(groups.len(), 2);
        assert_eq!(groups["u@host"], ["a".to_owned(), "b".to_owned()].into());
        let socket = Path::new("/daemon/a");
        assert_ne!(cache_path(socket, "u@host"), cache_path(socket, "v@host"));
        assert_ne!(cache_path(socket, "u@host"), cache_path(Path::new("/daemon/b"), "u@host"));
    }

    #[test]
    fn ssh_listing_shares_one_read_across_callers_then_expires_it() {
        use std::sync::Barrier;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("cache").join("source");
        let deadline = Instant::now() + LS_DEADLINE;
        let readers = Barrier::new(8);
        let reads = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            let tasks: Vec<_> = (0..8)
                .map(|_| {
                    scope.spawn(|| {
                        readers.wait();
                        cached_read(&path, deadline, || {
                            reads.fetch_add(1, Ordering::Relaxed);
                            std::thread::sleep(Duration::from_millis(50));
                            Ok(vec![json!({"sessionId":"far"})])
                        })
                    })
                })
                .collect();
            for task in tasks {
                assert_eq!(task.join().unwrap().unwrap()[0]["sessionId"], "far");
            }
        });
        assert_eq!(reads.load(Ordering::Relaxed), 1);
        assert!(
            cached_read(&path, deadline, || panic!("fresh cache")).unwrap()[0]["asOfMs"].is_u64()
        );
        let old = (0_u64, Ok::<_, String>(vec![json!({"sessionId":"expired"})]));
        std::fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
        assert_eq!(cached_read(&path, deadline, || Err("miss".into())), Err("miss".into()));
        assert_eq!(
            cached_read(&path, deadline, || panic!("duplicate failed read")),
            Err("miss".into())
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

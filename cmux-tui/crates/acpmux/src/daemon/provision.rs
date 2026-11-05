//! The VM provisioning exec gives the RUNNING daemon the person key (Cloud machines, M3 of
//! cmuxterm-hq `plans/cloud/ARCHITECTURE-2026-11.md`).
//!
//! Before, the provisioning exec stopped acpmux.service and the daemon, then started a keyed
//! daemon of its own (`start_keyed`): two Freestyle execs, and the unit (`Restart=always`,
//! `daemon run --take-over`) came back and competed with the keyed daemon for the socket. Now the
//! exec, which runs as root, hands the key to the daemon that already runs, over its unix socket
//! (`acpmux daemon enroll --person-key-fd 0`): one exec, one owner, no restart, and the agents keep
//! running.
//!
//! The rules of `--person-key-fd` hold (`hub/person.rs`):
//! - Only root may give it. The daemon takes `_acpmux/person_enroll` without the app's signature
//!   only on a connection whose peer uid (`SO_PEERCRED`) is 0 while the daemon itself is not root
//!   ([`accept_provisioner`]). An agent runs as the daemon's user, so it cannot; a daemon that runs
//!   as root (whose agents are root) never takes it.
//! - A Team-signed daemon never takes it: it enrolls the signed app by its signature.
//! - The daemon is not dumpable before it holds the key, and the key never reaches a child: the
//!   daemon makes itself not dumpable when it accepts a root connection, before it reads a byte.
//! - The key goes only to the real daemon. Before it writes the key, the provisioner checks the
//!   socket's peer process ([`check_daemon`]): not root, the owner of the acpmux home, running
//!   this same executable file, not dumpable (its /proc files are root's) and not traced. A
//!   squatter on the socket path, or a daemon too old to have made itself not dumpable, gets
//!   nothing (the exec then falls back to the keyed restart).

#[cfg(target_os = "linux")]
use anyhow::{Context, Result, anyhow};
#[cfg(target_os = "linux")]
use serde_json::Value;
#[cfg(target_os = "linux")]
use std::time::Duration;

/// How long `daemon enroll` waits for a daemon to answer on the socket (the unit may have just
/// been started): under the provisioning exec's 4.5 s budget.
#[cfg(target_os = "linux")]
const ANSWER_WAIT: Duration = Duration::from_millis(3_000);
/// How long one request on the provisioner's connection may take.
#[cfg(target_os = "linux")]
const REPLY_WAIT: Duration = Duration::from_millis(2_000);

/// Whether the peer of a socket connection the daemon just accepted is the provisioner: uid 0,
/// while this daemon is not root and not signed. Then the daemon is made not dumpable (once per
/// run) before the connection's first byte is read; when that fails, the peer is no provisioner.
#[cfg(target_os = "linux")]
pub(crate) fn accept_provisioner(stream: &tokio::net::UnixStream) -> bool {
    static NOT_DUMPABLE: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    let Ok(cred) = stream.peer_cred() else { return false };
    // SAFETY: geteuid has no preconditions.
    let own = unsafe { libc::geteuid() };
    if !is_provisioner(cred.uid(), own, cmux_link::app_caller::signed_app_build()) {
        return false;
    }
    *NOT_DUMPABLE.get_or_init(|| match super::not_dumpable() {
        Ok(()) => true,
        Err(e) => {
            tracing::warn!("a root connection may not give the person key: not dumpable failed: {e}");
            false
        }
    })
}

#[cfg(not(target_os = "linux"))]
pub(crate) fn accept_provisioner(_stream: &tokio::net::UnixStream) -> bool {
    false
}

/// The provisioner rule: a root peer of a daemon that is neither root nor signed.
pub(crate) fn is_provisioner(peer_uid: u32, own_uid: u32, signed: bool) -> bool {
    peer_uid == 0 && own_uid != 0 && !signed
}

/// `acpmux daemon enroll --person-key-fd FD`: as root, give the daemon that runs at this home's
/// socket the person key read from `fd`, and return its status (`personKey`, `personInstance`).
/// Never starts a daemon (as root it would make root-owned state in the user's home).
#[cfg(target_os = "linux")]
pub async fn enroll_running(fd: i32) -> Result<Value> {
    use std::fmt::Write as _;
    // SAFETY: geteuid has no preconditions.
    anyhow::ensure!(
        unsafe { libc::geteuid() } == 0,
        "`daemon enroll` is the VM provisioning exec's and runs as root; the app's own exec uses `daemon start --person-key-fd`"
    );
    super::not_dumpable().context("make the provisioner not dumpable before it reads the person key")?;
    let key = super::read_key_line(fd)?;
    let home = crate::config::home();
    let path = crate::config::socket_path();
    let stream = connect_within(&path, ANSWER_WAIT).await?;
    let mut conn = Lines::new(stream);
    // Its reply says the daemon accepted this connection, so a new daemon is not dumpable now.
    conn.call(r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#, 1)
        .await
        .context("initialize")?;
    let peer = conn.peer().context("read the daemon's peer credentials")?;
    check_daemon(peer, &home, &path)?;
    let mut line = zeroize::Zeroizing::new(String::with_capacity(160));
    // `key` is 64 lowercase hex characters (read_key_line checked): nothing to escape.
    let _ = write!(
        line,
        r#"{{"jsonrpc":"2.0","id":2,"method":"{}","params":{{"key":"{}"}}}}"#,
        crate::rpc::method::MUX_PERSON_ENROLL,
        &*key
    );
    let enrolled = conn.call(&line, 2).await.context("person_enroll")?;
    drop(line);
    if enrolled.get("via").and_then(Value::as_str) != Some("provisioner") {
        return Err(anyhow!("the daemon at {} did not take the key from the provisioner", path.display()));
    }
    let status = conn
        .call(
            &format!(r#"{{"jsonrpc":"2.0","id":3,"method":"{}","params":{{}}}}"#, crate::rpc::method::MUX_STATUS),
            3,
        )
        .await
        .context("status")?;
    Ok(status)
}

/// The daemon's process, by the socket's peer credentials (uid, pid).
#[cfg(target_os = "linux")]
#[derive(Debug, Clone, Copy)]
pub(crate) struct Peer {
    pub uid: u32,
    pub pid: i32,
}

/// Whether `peer` is the real daemon of `home`, before the key goes to it (module docs).
#[cfg(target_os = "linux")]
fn check_daemon(peer: Peer, home: &std::path::Path, socket: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let at = socket.display();
    anyhow::ensure!(peer.uid != 0, "the daemon at {at} runs as root: it takes no provisioned key");
    let owner = std::fs::metadata(home).with_context(|| format!("read {}", home.display()))?.uid();
    anyhow::ensure!(
        peer.uid == owner,
        "the daemon at {at} runs as uid {}, not as the owner of {} (uid {owner})",
        peer.uid,
        home.display()
    );
    let proc = std::path::PathBuf::from(format!("/proc/{}", peer.pid));
    let theirs = std::fs::metadata(proc.join("exe")).context("read the daemon's executable")?;
    let ours = std::fs::metadata("/proc/self/exe").context("read this executable")?;
    anyhow::ensure!(
        (theirs.dev(), theirs.ino()) == (ours.dev(), ours.ino()),
        "the daemon at {at} (pid {}) runs another executable than this one",
        peer.pid
    );
    let status = proc.join("status");
    let owned = std::fs::metadata(&status).context("read the daemon's status")?.uid();
    anyhow::ensure!(
        owned == 0,
        "the daemon at {at} (pid {}) did not make itself not dumpable: an older acpmux, which takes no provisioned key",
        peer.pid
    );
    let text = std::fs::read_to_string(&status).context("read the daemon's status")?;
    anyhow::ensure!(not_traced(&text), "the daemon at {at} (pid {}) is being traced", peer.pid);
    Ok(())
}

/// Whether a /proc status text says no tracer is attached.
pub(crate) fn not_traced(status: &str) -> bool {
    status
        .lines()
        .find_map(|l| l.strip_prefix("TracerPid:"))
        .is_some_and(|v| v.trim() == "0")
}

/// Connect to `path`, retrying while nothing listens yet, for at most `wait`.
#[cfg(target_os = "linux")]
async fn connect_within(path: &std::path::Path, wait: Duration) -> Result<tokio::net::UnixStream> {
    let deadline = tokio::time::Instant::now() + wait;
    loop {
        match tokio::net::UnixStream::connect(path).await {
            Ok(stream) => return Ok(stream),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) && tokio::time::Instant::now() < deadline =>
            {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(e) => {
                return Err(anyhow!("no daemon answers at {}: {e}", path.display()));
            }
        }
    }
}

/// Newline-delimited JSON-RPC over the provisioner's one connection.
#[cfg(target_os = "linux")]
struct Lines {
    read: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    write: tokio::net::unix::OwnedWriteHalf,
}

#[cfg(target_os = "linux")]
impl Lines {
    fn new(stream: tokio::net::UnixStream) -> Self {
        use tokio::io::AsyncBufReadExt;
        let (read, write) = stream.into_split();
        Self { read: tokio::io::BufReader::new(read).lines(), write }
    }

    fn peer(&self) -> Result<Peer> {
        let cred = self.write.as_ref().peer_cred()?;
        let pid = cred.pid().ok_or_else(|| anyhow!("the kernel reported no pid"))?;
        Ok(Peer { uid: cred.uid(), pid })
    }

    /// Send `line` and wait for the reply whose id is `id`; its result, or its error.
    async fn call(&mut self, line: &str, id: u64) -> Result<Value> {
        use tokio::io::AsyncWriteExt;
        self.write.write_all(line.as_bytes()).await?;
        self.write.write_all(b"\n").await?;
        self.write.flush().await?;
        let deadline = tokio::time::Instant::now() + REPLY_WAIT;
        loop {
            let next = tokio::time::timeout_at(deadline, self.read.next_line())
                .await
                .map_err(|_| anyhow!("the daemon did not answer within {REPLY_WAIT:?}"))??;
            let Some(text) = next else {
                return Err(anyhow!("the daemon closed the connection"));
            };
            let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
            if reply.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = reply.get("error") {
                let message = error.get("message").and_then(Value::as_str).unwrap_or("error");
                return Err(anyhow!("{message}"));
            }
            return Ok(reply.get("result").cloned().unwrap_or(Value::Null));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{is_provisioner, not_traced};

    #[test]
    fn only_a_root_peer_of_an_unsigned_user_daemon_provisions() {
        assert!(is_provisioner(0, 1000, false));
        // The daemon's own user (an agent) never is.
        assert!(!is_provisioner(1000, 1000, false));
        assert!(!is_provisioner(1001, 1000, false));
        // A root daemon's agents are root.
        assert!(!is_provisioner(0, 0, false));
        // A signed daemon enrolls the app by its signature only.
        assert!(!is_provisioner(0, 1000, true));
    }

    #[test]
    fn a_traced_daemon_is_refused() {
        assert!(not_traced("Name:\tacpmux\nTracerPid:\t0\nUid:\t1000\n"));
        assert!(!not_traced("Name:\tacpmux\nTracerPid:\t4242\n"));
        assert!(!not_traced("Name:\tacpmux\n"));
    }
}

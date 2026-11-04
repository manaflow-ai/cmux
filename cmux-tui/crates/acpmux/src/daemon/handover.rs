//! A direct `daemon run --ready-fd` launch that loses the lock race reports the
//! running daemon's endpoint. The app uses this path instead of CLI auto-start.

use std::path::Path;
#[cfg(unix)]
use std::time::Duration;

use serde_json::{Value, json};

/// How long a start waits for a DEV daemon it asked to hand over before going on as usual.
#[cfg(unix)]
const RECLAIM_WAIT: Duration = Duration::from_secs(30);

pub(super) enum Started {
    /// The old daemon was stopping; this start is its successor.
    Acquired(super::lock::DaemonLock),
    /// Another start won; answer the launcher and exit without serving.
    Ready(Value),
}

/// Wait for the lock to become ours or for its winner to answer at this launch's
/// socket. A stopping old daemon may have no successor yet, so this launch still
/// tries the normal nonblocking acquisition. It never removes another daemon's
/// files. A live lock holder is retried until it answers or releases the lock.
pub(super) async fn wait(home: &Path, socket: &Path) -> Option<Started> {
    loop {
        match super::acquire_lock(&home.join("daemon.lock")) {
            Ok(lock) => return Some(Started::Acquired(lock)),
            Err(e) if e.downcast_ref::<super::LockHeld>().is_some() => {}
            Err(_) => return None,
        }
        if let Ok(client) = crate::client::Client::connect(socket).await
            && let Ok(status) = client.request(crate::rpc::method::MUX_STATUS, json!({})).await
        {
            // ACPMUX_SOCKET may name another home's daemon. Its endpoint is
            // not this launch's winner, even though it answers.
            if status.get("home").and_then(Value::as_str).map(Path::new) != Some(home)
                || status.get("socket").and_then(Value::as_str).map(Path::new) != Some(socket)
            {
                return None;
            }
            return Some(Started::Ready(json!({
                "ready": true,
                // Keyed CLI starts still reject a winner holding another key;
                // they already check lockHeld before accepting a ready line.
                "lockHeld": true,
                "pid": status["pid"],
                "socket": status["socket"],
                "listen": status["listen"],
                "webUrl": status["webUrl"],
            })));
        }
        tokio::time::sleep(super::HANDOVER_RETRY).await;
    }
}

/// A start of a home of NIGHTLY's whose lock a DEV build holds asks that daemon to hand the home
/// over (agents kept) and waits for it to let go, so this launch serves the home instead of
/// reporting the DEV daemon as its winner (`exe_path::reclaims_home`). Any other holder is left
/// alone. Best effort: a holder that stays is waited on as any holder is ([`wait`]).
#[cfg(unix)]
pub(super) async fn reclaim_from_dev(lock: &Path, socket: &Path) {
    let Some(pid) = super::lock::live_holder_pid(lock) else { return };
    let Some(exe) = crate::agent_host::tree::exe(pid) else { return };
    if !super::exe_path::current_reclaims_home(&exe) {
        return;
    }
    tracing::warn!(pid, exe = %exe.display(), "a DEV build's daemon holds this home; taking it back");
    super::take_over_holder(socket).await;
    let release = super::wait_for_lock_release(lock.to_owned());
    if tokio::time::timeout(RECLAIM_WAIT, release).await.is_err() {
        tracing::warn!(pid, "the DEV build's daemon has not let go of this home yet");
    }
}

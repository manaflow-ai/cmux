//! A direct `daemon run --ready-fd` launch that loses the lock race reports the
//! running daemon's endpoint. The app uses this path instead of CLI auto-start.

use std::path::Path;
#[cfg(unix)]
use std::time::Duration;

use serde_json::{Value, json};

/// How long a start spends asking a DEV daemon to hand over and waiting for it to let go, before
/// going on as usual. Under the app's launch stall limit (20 s without a log write).
///
/// A DEV daemon asked to hand over may accept and never let go, or never answer at all; a launch
/// the person is watching has to go on serving rather than wait on it forever.
#[cfg(unix)]
// timeout: hazard is a hung hand-over holder; the fallback is to go on with the normal start.
const RECLAIM_WAIT: Duration = Duration::from_secs(15);

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

/// What asking a lock's holder to hand its home over came to.
#[cfg(unix)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Ask {
    /// It took the request: its lock is about to go.
    Accepted,
    /// It does not answer yet (a holder still starting has no socket): ask again.
    NotYet,
    /// It refused, or what answers is not the holder this start classified: leave it alone.
    Stop,
}

/// A start of a home of NIGHTLY's whose lock a DEV build holds asks that daemon to hand the home
/// over (agents kept) and waits for it to let go, so this launch serves the home instead of
/// reporting the DEV daemon as its winner (`exe_path::reclaims_home`). Any other holder is left
/// alone. The ask and the wait share [`RECLAIM_WAIT`]; a holder still there after it is waited on
/// as any holder is ([`wait`]).
#[cfg(unix)]
pub(super) async fn reclaim_from_dev(lock: &Path, socket: &Path, home: &Path) {
    let Some(pid) = super::lock::live_holder_pid(lock) else { return };
    let Some(exe) = crate::agent_host::tree::exe(pid) else { return };
    if !super::exe_path::current_reclaims_home(&exe) {
        return;
    }
    // A holder serving another socket cannot be reached here; waiting would only delay this start.
    if super::lock::holder_socket(lock).is_some_and(|held| !super::same_path(&held, socket)) {
        return;
    }
    tracing::warn!(pid, exe = %exe.display(), "a DEV build's daemon holds this home; taking it back");
    let ask = || async move {
        // Gone already (it stopped by itself, or crashed): the lock is free or another's.
        if super::lock::live_holder_pid(lock) != Some(pid) {
            return Ask::Stop;
        }
        ask_holder(socket, home, pid).await
    };
    let release = super::wait_for_lock_release(lock.to_owned());
    if !drive_reclaim(ask, release, RECLAIM_WAIT, super::HANDOVER_RETRY).await {
        tracing::warn!(pid, "the DEV build's daemon did not hand this home over");
    }
}

/// Asks until the holder takes the request or refuses, then waits for `release`, all within
/// `budget`. True once the holder let go.
#[cfg(unix)]
async fn drive_reclaim<A, AF, R>(mut ask: A, release: R, budget: Duration, retry: Duration) -> bool
where
    A: FnMut() -> AF,
    AF: std::future::Future<Output = Ask>,
    R: std::future::Future,
{
    let run = async {
        loop {
            match ask().await {
                Ask::Accepted => break,
                Ask::Stop => return false,
                Ask::NotYet => tokio::time::sleep(retry).await,
            }
        }
        release.await;
        true
    };
    tokio::time::timeout(budget, run).await.unwrap_or(false)
}

/// One ask of the daemon at `socket`: `_acpmux/shutdown` with its agents kept, once its status
/// names this `home`, this `socket` and the `pid` that was classified as a DEV build's.
#[cfg(unix)]
async fn ask_holder(socket: &Path, home: &Path, pid: u32) -> Ask {
    let Ok(client) = crate::client::Client::connect(socket).await else { return Ask::NotYet };
    let Ok(status) = client.request(crate::rpc::method::MUX_STATUS, json!({})).await else {
        return Ask::NotYet;
    };
    let names = |key: &str, want: &Path| {
        status
            .get(key)
            .and_then(Value::as_str)
            .is_some_and(|got| super::same_path(Path::new(got), want))
    };
    if !names("home", home)
        || !names("socket", socket)
        || status.get("pid").and_then(Value::as_u64) != Some(u64::from(pid))
    {
        return Ask::Stop;
    }
    // A closed connection is a holder already stopping, as for `take_over_holder`; any other
    // error is a refusal, and there is nothing more to ask.
    match client.request(crate::rpc::method::MUX_SHUTDOWN, json!({})).await {
        Ok(_) => Ask::Accepted,
        Err(_) if client.is_closed() => Ask::Accepted,
        Err(_) => Ask::Stop,
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::cell::Cell;

    // Production reclaim waits on `RECLAIM_WAIT` and on the holder's liveness; these two only
    // drive the paused-clock assertions below.
    // timeout: test-only bound for the paused-clock reclaim assertions.
    const BUDGET: Duration = Duration::from_secs(15);
    // timeout: test-only retry cadence for the same paused-clock assertions.
    const RETRY: Duration = Duration::from_millis(50);

    #[tokio::test(start_paused = true)]
    async fn a_holder_still_starting_is_asked_again_once_it_answers() {
        let asks = Cell::new(0);
        let ask = || {
            asks.set(asks.get() + 1);
            let answer = if asks.get() < 3 { Ask::NotYet } else { Ask::Accepted };
            async move { answer }
        };
        assert!(drive_reclaim(ask, std::future::ready(()), BUDGET, RETRY).await);
        assert_eq!(asks.get(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn a_refusal_or_a_foreign_daemon_ends_the_wait_at_once() {
        let started = tokio::time::Instant::now();
        let ask = || async { Ask::Stop };
        assert!(!drive_reclaim(ask, std::future::pending::<()>(), BUDGET, RETRY).await);
        assert_eq!(started.elapsed(), Duration::ZERO);
    }

    #[tokio::test(start_paused = true)]
    async fn a_holder_that_never_answers_or_never_lets_go_costs_only_the_budget() {
        let started = tokio::time::Instant::now();
        let silent = || std::future::pending::<Ask>();
        assert!(!drive_reclaim(silent, std::future::ready(()), BUDGET, RETRY).await);
        assert_eq!(started.elapsed(), BUDGET);

        let started = tokio::time::Instant::now();
        let accepted = || async { Ask::Accepted };
        assert!(!drive_reclaim(accepted, std::future::pending::<()>(), BUDGET, RETRY).await);
        assert_eq!(started.elapsed(), BUDGET);
    }
}

//! Connecting to a daemon that already runs, never starting one. A listing (`acpmux ls`) is
//! read by scripts and census probes on every host; started on a dead socket, or under a home
//! no daemon serves, it used to bring up an empty daemon and report "no sessions", which read
//! as a host with nothing on it (hq#4897 failure 4, hq#5075). While a live daemon holds this
//! home's lock without serving yet (a restart's handover), the listing waits for its socket.

use super::{HANDOVER_BUDGET, HANDOVER_RETRY, live_holder};
use crate::cli::errors::{AppError, Code};
use crate::client::Client;
use crate::config::{home, socket_path};
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

/// Connect to the daemon that serves this home, starting none. No daemon: a `no_daemon` error.
pub async fn connect_running() -> Result<Arc<Client>> {
    let path = socket_path();
    let lock = home().join("daemon.lock");
    connect_running_with(
        &path,
        || live_holder(&lock).is_some(),
        HANDOVER_BUDGET,
        || Client::connect(&path),
    )
    .await
}

async fn connect_running_with<T, H, F, Fut>(
    path: &Path,
    held: H,
    budget: Duration,
    connect: F,
) -> Result<T>
where
    H: Fn() -> bool,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        if let Ok(value) = connect().await {
            return Ok(value);
        }
        if !held() {
            return Err(AppError::new(
                Code::Runtime,
                "no_daemon",
                format!(
                    "no acpmux daemon at {} (listing starts none: `acpmux daemon start`)",
                    path.display()
                ),
            )
            .into());
        }
        if tokio::time::Instant::now() + HANDOVER_RETRY >= deadline {
            return Err(AppError::new(
                Code::Runtime,
                "daemon_not_serving",
                format!(
                    "an acpmux daemon holds {} but serves no socket at {} after {budget:?}",
                    home().join("daemon.lock").display(),
                    path.display()
                ),
            )
            .retryable()
            .into());
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn detail(e: &anyhow::Error) -> String {
        e.downcast_ref::<AppError>().map(|e| e.detail.clone()).unwrap_or_default()
    }

    #[tokio::test]
    async fn no_daemon_is_an_error_at_once_and_nothing_is_started() {
        let tries = AtomicUsize::new(0);
        let started = std::time::Instant::now();
        let got = connect_running_with(
            Path::new("/x/acpmux.sock"),
            || false,
            HANDOVER_BUDGET,
            || {
                tries.fetch_add(1, Ordering::SeqCst);
                async { Err::<(), _>(anyhow::anyhow!("refused")) }
            },
        )
        .await;
        let e = got.unwrap_err();
        assert_eq!(detail(&e), "no_daemon", "{e}");
        assert!(e.to_string().contains("/x/acpmux.sock"), "{e}");
        assert_eq!(tries.load(Ordering::SeqCst), 1, "one try, no wait");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test(start_paused = true)]
    async fn a_daemon_in_its_handover_is_waited_for() {
        let tries = AtomicUsize::new(0);
        let got = connect_running_with(
            Path::new("/x/s"),
            || true,
            HANDOVER_BUDGET,
            || {
                let n = tries.fetch_add(1, Ordering::SeqCst);
                async move { if n < 3 { Err(anyhow::anyhow!("not yet")) } else { Ok(n) } }
            },
        )
        .await;
        assert_eq!(got.unwrap(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn a_lock_holder_that_never_serves_ends_the_wait() {
        let got = connect_running_with(
            Path::new("/x/s"),
            || true,
            Duration::from_secs(2),
            || async { Err::<(), _>(anyhow::anyhow!("not yet")) },
        )
        .await;
        let e = got.unwrap_err();
        assert_eq!(detail(&e), "daemon_not_serving", "{e}");
    }

    #[cfg(unix)]
    #[test]
    fn the_lock_holder_is_read_without_taking_the_lock_or_making_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join("daemon.lock");
        assert_eq!(live_holder(&lock), None);
        assert!(!lock.exists(), "a probe made the lock file");
        std::fs::write(&lock, format!("{}\n", std::process::id())).unwrap();
        assert_eq!(live_holder(&lock), Some(std::process::id()));
        // A pid no process has (above the default pid_max): no holder.
        std::fs::write(&lock, "999999999\n").unwrap();
        assert_eq!(live_holder(&lock), None);
    }
}

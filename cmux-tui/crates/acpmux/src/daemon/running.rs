//! Connecting to a daemon that already runs, never starting one. A listing (`acpmux ls`) is
//! read by scripts and census probes on every host; started on a dead socket, or under a home
//! no daemon serves, it used to bring up an empty daemon and report "no sessions", which read
//! as a host with nothing on it (hq#4897 failure 4, hq#5075). While a live daemon holds this
//! home's lock without serving yet (a restart's handover), the listing waits for its socket.

use super::{HANDOVER_RETRY, lock_has_live_holder};
use crate::cli::errors::{AppError, Code};
use crate::client::Client;
use crate::config::{home, socket_path};
use anyhow::Result;
use std::path::Path;
use std::sync::Arc;
#[cfg(test)]
use std::time::Duration;

/// Connect to the daemon that serves this home, starting none. No daemon: a `no_daemon` error.
pub async fn connect_running() -> Result<Arc<Client>> {
    let path = socket_path();
    let lock = home().join("daemon.lock");
    // This home's daemon serves another socket: no wait makes it serve this one.
    #[cfg(unix)]
    if Client::connect(&path).await.is_err()
        && lock_has_live_holder(&lock)
        && let Some(other) = super::holder_elsewhere(&path).await
    {
        return Err(super::serves_elsewhere(&path, &other));
    }
    connect_running_with(&path, || lock_has_live_holder(&lock), || Client::connect(&path)).await
}

async fn connect_running_with<T, H, F, Fut>(path: &Path, held: H, connect: F) -> Result<T>
where
    H: Fn() -> bool,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    loop {
        // A closed socket makes connect return immediately. An open socket is
        // allowed to remain slow as long as its daemon lock holder lives.
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
            || {
                let n = tries.fetch_add(1, Ordering::SeqCst);
                async move { if n < 3 { Err(anyhow::anyhow!("not yet")) } else { Ok(n) } }
            },
        )
        .await;
        assert_eq!(got.unwrap(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_but_alive_daemon_is_not_cut_off_by_the_old_budget() {
        let task = tokio::spawn(connect_running_with(
            Path::new("/x/s"),
            || true,
            || async {
                tokio::time::sleep(Duration::from_secs(31)).await;
                Ok::<_, anyhow::Error>(())
            },
        ));
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(31)).await;
        assert!(task.await.unwrap().is_ok());
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_socket_fails_fast_even_when_the_connect_future_is_slow() {
        let got = connect_running_with(
            Path::new("/x/s"),
            || false,
            || async { Err::<(), _>(anyhow::anyhow!("connection refused")) },
        )
        .await;
        let e = got.unwrap_err();
        assert_eq!(detail(&e), "no_daemon", "{e}");
    }

    #[cfg(unix)]
    #[test]
    fn the_lock_probe_requires_the_kernel_lock_not_just_a_pid_file() {
        let dir = tempfile::tempdir().unwrap();
        let lock = dir.path().join("daemon.lock");
        assert!(!lock_has_live_holder(&lock));
        assert!(!lock.exists(), "a probe made the lock file");
        std::fs::write(&lock, format!("{}\n", std::process::id())).unwrap();
        assert!(!lock_has_live_holder(&lock), "a stale pid is not a lock holder");
        let file = std::fs::OpenOptions::new().read(true).write(true).open(&lock).unwrap();
        // SAFETY: this test owns the descriptor and releases the probe lock below.
        assert_eq!(
            unsafe {
                libc::flock(
                    std::os::unix::io::AsRawFd::as_raw_fd(&file),
                    libc::LOCK_EX | libc::LOCK_NB,
                )
            },
            0
        );
        assert!(lock_has_live_holder(&lock));
        unsafe { libc::flock(std::os::unix::io::AsRawFd::as_raw_fd(&file), libc::LOCK_UN) };
        drop(file);
        // A pid no process has (above the default pid_max) is still not a holder.
        std::fs::write(&lock, "999999999\n").unwrap();
        assert!(!lock_has_live_holder(&lock));
    }
}

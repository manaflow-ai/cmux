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
mod tests;

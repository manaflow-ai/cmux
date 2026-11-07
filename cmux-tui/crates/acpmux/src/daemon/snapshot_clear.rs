//! App sign-out clears through the live writer, or exclusively under the daemon lock when
//! none runs. Never starts a daemon merely to erase old copies, and never deletes beside one.

use super::*;
use std::path::Path;

pub(crate) async fn clear_peer_snapshots() -> Result<()> {
    clear_at(&home(), &socket_path()).await
}

async fn clear_at(home: &Path, socket: &Path) -> Result<()> {
    // timeout: an accepted socket that never completes initialization is a hung
    // writer; after this grace the lock-protected path can safely decide.
    const SNAPSHOT_CONNECT_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);
    if let Ok(Ok(client)) =
        tokio::time::timeout(SNAPSHOT_CONNECT_BUDGET, Client::connect_without_caller(socket)).await
    {
        let status = client.request(crate::rpc::method::MUX_STATUS, serde_json::json!({})).await?;
        let served = status
            .get("home")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("daemon did not identify its home"))?;
        if std::fs::canonicalize(served)? != std::fs::canonicalize(home)? {
            anyhow::bail!("refusing to clear peer snapshots belonging to another daemon home");
        }
        client.request("_acpmux/peer_snapshots_clear", serde_json::json!({})).await?;
        return Ok(());
    }
    crate::config::private_state_dir(home)?;
    // A live but unresponsive writer holds this lock: fail instead of erasing underneath it.
    let _lock = acquire_lock(&home.join("daemon.lock"))?;
    crate::hub::peer_snapshot::clear_offline(home)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn offline_peer_snapshot_clear_never_runs_beside_a_live_writer() {
        let dir = cmux_unix_socket::short_test_dir("acpmux-clear-lock");
        let held = acquire_lock(&dir.path().join("daemon.lock")).unwrap();
        let socket = dir.path().join("missing.sock");
        assert!(clear_at(dir.path(), &socket).await.is_err());
        drop(held);
        clear_at(dir.path(), &socket).await.unwrap();
        assert!(!socket.exists(), "clearing must not start a daemon");
    }
}

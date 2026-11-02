//! A direct `daemon run --ready-fd` launch that loses the lock race reports the
//! running daemon's endpoint. The app uses this path instead of CLI auto-start.

use std::path::Path;

use serde_json::{Value, json};

pub(super) enum Started {
    /// The old daemon was stopping; this start is its successor.
    Acquired(super::lock::DaemonLock),
    /// Another start won; answer the launcher and exit without serving.
    Ready(Value),
}

/// Wait for the lock to become ours or for its winner to answer at this launch's
/// socket. A stopping old daemon may have no successor yet, so this launch still
/// tries the normal nonblocking acquisition. It never removes another daemon's
/// files. The deadline bounds connecting, initialize, status and retries together.
pub(super) async fn wait(home: &Path, socket: &Path) -> Option<Started> {
    tokio::time::timeout(super::HANDOVER_BUDGET, async {
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
    })
    .await
    .ok()
    .flatten()
}

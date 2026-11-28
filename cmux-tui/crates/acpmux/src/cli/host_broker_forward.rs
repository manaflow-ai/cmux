//! `acpmux machine broker-forward OWNER --socket PATH` (RFD 0127 cut 2): a lane machine's own
//! socket for its lane-gh broker that runs over the held carrier link instead of an `ssh -R`
//! forward. Each connection to PATH opens one `_acpmux/remote.pipe`
//! `{machine: OWNER, service: "lane-gh-broker"}` on this machine's daemon and carries its bytes,
//! so `LANE_GH_SOCKET=PATH lane-gh ...` uses it. It holds nothing between connections and
//! reaches the daemon fresh each time, so it outlives a daemon restart. Opt-in: the
//! `ssh -R` socket stays where `lane-gh` looks by default.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::rpc::{Message, method};

pub async fn run(owner: String, socket: PathBuf) -> Result<()> {
    let listener = bind(&socket)?;
    eprintln!(
        "broker-forward: {} reaches {owner}'s lane-gh broker over the carrier",
        socket.display()
    );
    // One task per connection, owned by this command: they end when it does.
    let connections = cmux_scope::Scope::new("machine broker-forward");
    loop {
        let (conn, _) = listener.accept().await.context("accept")?;
        let owner = owner.clone();
        connections.spawn_until_cancelled("broker-forward connection", async move {
            if let Err(e) = carry(conn, &owner, &crate::config::socket_path()).await {
                eprintln!("broker-forward: {e:#}");
            }
        });
    }
}

/// Listen at `socket`, replacing a stale socket file there (never any other kind of file).
fn bind(socket: &Path) -> Result<UnixListener> {
    use std::os::unix::fs::FileTypeExt;
    if let Some(dir) = socket.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    match std::fs::symlink_metadata(socket) {
        Ok(meta) if meta.file_type().is_socket() => {
            if std::os::unix::net::UnixStream::connect(socket).is_ok() {
                return Err(anyhow!("{} is already served", socket.display()));
            }
            std::fs::remove_file(socket)
                .with_context(|| format!("remove stale {}", socket.display()))?;
        }
        Ok(_) => return Err(anyhow!("{} exists and is not a socket", socket.display())),
        Err(_) => {}
    }
    UnixListener::bind(socket).with_context(|| format!("listen at {}", socket.display()))
}

/// Carry one client connection over a fresh `remote.pipe` to `owner`'s broker.
pub(crate) async fn carry(mut client: UnixStream, owner: &str, daemon: &Path) -> Result<()> {
    let mut pipe = open_pipe(owner, daemon).await?;
    tokio::io::copy_bidirectional(&mut client, &mut pipe).await.ok();
    Ok(())
}

/// A `remote.pipe` to `owner`'s lane-gh broker on the daemon at `daemon`, past its reply line.
pub(crate) async fn open_pipe(owner: &str, daemon: &Path) -> Result<UnixStream> {
    let mut stream = UnixStream::connect(daemon)
        .await
        .with_context(|| format!("this machine's daemon at {}", daemon.display()))?;
    // `hub_carrier::LANE_GH_BROKER_SERVICE`; the CLI builds without the `hub-carrier` feature.
    let request = Message::request(
        1,
        method::MUX_REMOTE_PIPE,
        json!({"machine": owner, "service": "lane-gh-broker"}),
    );
    stream.write_all(request.to_line().as_bytes()).await?;
    // One line, read a byte at a time so no carried byte is buffered away.
    let mut line = Vec::new();
    let mut reader = BufReader::with_capacity(1, &mut stream);
    reader.read_until(b'\n', &mut line).await?;
    let reply: Value = serde_json::from_slice(&line).context("the daemon's remote.pipe reply")?;
    if let Some(error) = reply.get("error") {
        let message = error.get("message").and_then(Value::as_str).unwrap_or("refused");
        let reason = error.pointer("/data/reason").and_then(Value::as_str).unwrap_or("");
        return Err(anyhow!("{owner}'s lane-gh broker: {message} ({reason})"));
    }
    Ok(stream)
}

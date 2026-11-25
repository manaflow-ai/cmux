//! `acpmux machine broker-forward OWNER --socket PATH` (RFD 0127 cut 2): a lane machine's own
//! socket for its lane-gh broker that runs over the held carrier link instead of an `ssh -R`
//! forward. Each connection to PATH opens one `_acpmux/remote.pipe`
//! `{machine: OWNER, service: "lane-gh-broker"}` on this machine's daemon and carries its bytes,
//! so `LANE_GH_SOCKET=PATH lane-gh ...` uses it. It holds nothing between connections and
//! reaches the daemon fresh each time, so it outlives a daemon restart. Opt-in: the
//! `ssh -R` socket stays where `lane-gh` looks by default.
//!
//! `lane-gh` speaks first (one request line, then the broker's reply), so each connection's
//! first bytes go with its `remote.pipe` as `early` bytes and ride right behind the stream's
//! OPEN: the reply comes one relay round trip after the connect, not two (the OPEN's answer,
//! then the request and its reply). A daemon from before `early` carries them after its reply.

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

/// The most of a connection's first bytes sent as a pipe's `early` bytes
/// (`HubCarrier::EARLY_BYTES`; the CLI builds without the `hub-carrier` feature).
const EARLY_BYTES: usize = 64 * 1024;
/// How long a connection's first bytes are waited for before its pipe opens without them: a
/// `lane-gh` call writes its request as soon as it connects.
const FIRST_BYTES_WAIT: std::time::Duration = std::time::Duration::from_millis(100);

/// Carry one client connection over a fresh `remote.pipe` to `owner`'s broker.
pub(crate) async fn carry(mut client: UnixStream, owner: &str, daemon: &Path) -> Result<()> {
    let early = first_bytes(&mut client).await;
    let mut pipe = open_pipe(owner, daemon, &early).await?;
    tokio::io::copy_bidirectional(&mut client, &mut pipe).await.ok();
    Ok(())
}

/// What the client sent first, within [`FIRST_BYTES_WAIT`] (empty when it sent nothing yet or
/// closed: the pipe then opens without early bytes and carries whatever comes).
async fn first_bytes(client: &mut UnixStream) -> Vec<u8> {
    use tokio::io::AsyncReadExt;
    let mut early = vec![0u8; EARLY_BYTES];
    let n = match tokio::time::timeout(FIRST_BYTES_WAIT, client.read(&mut early)).await {
        Ok(Ok(n)) => n,
        _ => 0,
    };
    early.truncate(n);
    early
}

/// A `remote.pipe` to `owner`'s lane-gh broker on the daemon at `daemon`, past its reply line,
/// whose stream starts with `early`, sent with the request so the daemon puts them behind the
/// stream's OPEN.
pub(crate) async fn open_pipe(owner: &str, daemon: &Path, early: &[u8]) -> Result<UnixStream> {
    let mut stream = UnixStream::connect(daemon)
        .await
        .with_context(|| format!("this machine's daemon at {}", daemon.display()))?;
    // `hub_carrier::LANE_GH_BROKER_SERVICE`; the CLI builds without the `hub-carrier` feature.
    let mut params = json!({"machine": owner, "service": "lane-gh-broker"});
    if !early.is_empty() {
        params["early"] = early.len().into();
    }
    let request = Message::request(1, method::MUX_REMOTE_PIPE, params);
    // One write: the request line and its early bytes reach the daemon together.
    let mut out = request.to_line().into_bytes();
    out.extend_from_slice(early);
    stream.write_all(&out).await?;
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

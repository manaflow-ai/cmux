//! This Mac reaching another of the person's machines
//! (docs/multi-machine-sessions.md, "One link for every device").
//!
//! hostd already keeps a warm signaling socket and cached ICE for answering
//! phones. The same socket dials out: the hub admits a dial from any of the
//! person's devices to any of their Macs, and a subscribed session's signals
//! come back to the dialer. So `cmux machine NAME ...` asks hostd, over a
//! local socket, to open a channel on a link to NAME, and hostd splices it.
//!
//! The local socket sits beside the app's daemon socket
//! (`<dir>/<session>.link.sock`, the folder `0700` as the daemon's, the
//! socket `0600`) and serves only this user (peer uid checked). One JSON line
//! asks; one JSON line answers; after `{"ok":true}` the socket is the channel.
//!
//! - `{"op":"machines"}`: the person's Macs from the hub (`GET /v1/me/devices`),
//!   with presence, this one marked.
//! - `{"op":"open","peer":DEVICE_ID,"service":S,"args":{},"origin":"person"|"agent"}`:
//!   a link to the peer (reused while it lives), `auth` as a Mac with this
//!   Mac's identity key (the peer may answer `pending` while its person
//!   decides; each is passed on as `{"pending":true}`), then the channel.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::{ChannelEvent, DialOptions, Link, LinkConfig, SignalingClient, TransportKind};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;

use crate::auth::Tokens;
use crate::host::IceSource;
use crate::pairing::MacIdentity;

/// How long a dial may take before the CLI hears `timeout`.
const DIAL_TIMEOUT: Duration = Duration::from_secs(20);
/// How long the peer's person may take to decide (its `APPROVAL_WAIT` and a margin).
const AUTH_TIMEOUT: Duration = Duration::from_secs(150);
/// A request line's size limit.
const MAX_REQUEST: usize = 64 * 1024;

/// What dialing needs; shared by every request.
pub struct Dialer {
    pub device_id: String,
    pub device_name: String,
    pub base_url: String,
    pub tokens: Arc<Tokens>,
    pub ice: IceSource,
    /// The current signaling socket (`None` while reconnecting).
    pub signaling: watch::Receiver<Option<SignalingClient>>,
    pub identity: watch::Receiver<Option<MacIdentity>>,
    pub activity: Arc<crate::activity::Activity>,
    /// Live links by peer device id (one per peer, reused by every request).
    pub links: Mutex<HashMap<String, Arc<Link>>>,
}

/// `<dir>/<session>.link.sock` for the daemon socket `<dir>/<session>.sock`.
pub fn socket_path(daemon_socket: &Path) -> PathBuf {
    let stem = daemon_socket.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    daemon_socket.with_file_name(format!("{stem}.link.sock"))
}

/// Serve the local socket until the task is dropped.
pub async fn serve(path: PathBuf, dialer: Arc<Dialer>) -> Result<()> {
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    }
    tracing::info!(path = %path.display(), "machine link socket");
    loop {
        let (stream, _) = listener.accept().await?;
        if !same_user(&stream) {
            tracing::warn!("refusing a machine link request from another user");
            continue;
        }
        let dialer = Arc::clone(&dialer);
        tokio::spawn(async move {
            if let Err(error) = handle(stream, dialer).await {
                tracing::info!("machine link request ended: {error:#}");
            }
        });
    }
}

fn same_user(stream: &UnixStream) -> bool {
    match stream.peer_cred() {
        // SAFETY: getuid has no preconditions and cannot fail.
        Ok(cred) => cred.uid() == unsafe { libc::getuid() },
        Err(_) => false,
    }
}

async fn reply(stream: &mut (impl AsyncWriteExt + Unpin), value: Value) -> Result<()> {
    let mut line = value.to_string().into_bytes();
    line.push(b'\n');
    stream.write_all(&line).await?;
    Ok(())
}

async fn handle(stream: UnixStream, dialer: Arc<Dialer>) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut read = BufReader::new(read);
    let mut line = Vec::new();
    (&mut read).take(MAX_REQUEST as u64).read_until(b'\n', &mut line).await?;
    let request: Value = match serde_json::from_slice(&line) {
        Ok(value) => value,
        Err(_) => return reply(&mut write, json!({"error": "bad_request", "message": "one JSON line"})).await,
    };
    match request.get("op").and_then(Value::as_str) {
        Some("machines") => {
            let answer = match machines(&dialer).await {
                Ok(list) => json!({"ok": true, "machines": list}),
                Err(error) => json!({"error": "unavailable", "message": format!("{error:#}")}),
            };
            reply(&mut write, answer).await
        }
        Some("open") => open(&dialer, &request, read, write).await,
        _ => reply(&mut write, json!({"error": "bad_request", "message": "op is machines or open"})).await,
    }
}

async fn machines(dialer: &Dialer) -> Result<Vec<Value>> {
    let token = dialer.tokens.access_token().await?;
    let devices = ApiClient::new(&dialer.base_url, &token).my_devices().await?;
    Ok(devices
        .into_iter()
        .filter(|d| d.kind == "mac")
        .map(|d| {
            json!({
                "device_id": d.device_id,
                "name": d.name,
                "online": d.online,
                "machine_id": d.machine_id,
                "this": d.device_id.eq_ignore_ascii_case(&dialer.device_id),
            })
        })
        .collect())
}

async fn open(
    dialer: &Arc<Dialer>,
    request: &Value,
    mut read: BufReader<tokio::net::unix::OwnedReadHalf>,
    mut write: tokio::net::unix::OwnedWriteHalf,
) -> Result<()> {
    let text = |key: &str| request.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let (peer, service) = (text("peer"), text("service"));
    let origin = match text("origin").as_str() {
        "person" => "person",
        // Anything else counts as an agent: the target only ever narrows on it.
        _ => "agent",
    };
    if uuid::Uuid::parse_str(&peer).is_err() || service.is_empty() || service == "auth" {
        return reply(&mut write, json!({"error": "bad_request", "message": "peer is a device id; service is not auth"}))
            .await;
    }
    if peer.eq_ignore_ascii_case(&dialer.device_id) {
        return reply(&mut write, json!({"error": "bad_request", "message": "that is this Mac"})).await;
    }
    let started = Instant::now();
    let link = match link_to(dialer, &peer, &mut write).await {
        Ok(link) => link,
        Err((code, message)) => {
            record(dialer, &peer, &service, origin, code);
            return reply(&mut write, json!({"error": code, "message": message})).await;
        }
    };
    let mut args = request.get("args").cloned().unwrap_or_else(|| json!({}));
    if let Some(object) = args.as_object_mut() {
        object.insert("origin".into(), json!(origin));
    }
    let channel = match link.open(&service, args).await {
        Ok(channel) => channel,
        Err(error) => {
            record(dialer, &peer, &service, origin, "closed");
            return reply(&mut write, json!({"error": "closed", "message": error.to_string()})).await;
        }
    };
    record(dialer, &peer, &service, origin, "allowed");
    reply(&mut write, json!({"ok": true, "ms": started.elapsed().as_millis() as u64})).await?;
    splice(channel, read.get_mut(), &mut write).await;
    Ok(())
}

fn record(dialer: &Dialer, peer: &str, service: &str, origin: &'static str, decision: &str) {
    dialer.activity.record(crate::activity::Entry {
        at_ms: crate::activity::now_ms(),
        peer: peer.to_owned(),
        kind: "mac",
        direction: "out",
        service: service.to_owned(),
        decision: decision.to_owned(),
        target: Some(format!("origin:{origin}")),
    });
}

/// Bytes both ways until either side ends; a channel close ends the socket.
async fn splice(
    channel: cmux_mobile_link::Channel,
    read: &mut tokio::net::unix::OwnedReadHalf,
    write: &mut tokio::net::unix::OwnedWriteHalf,
) {
    let (sender, mut receiver) = channel.split();
    let upstream = async {
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            match read.read(&mut buffer).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if sender.send(Bytes::copy_from_slice(&buffer[..n])).await.is_err() {
                        break;
                    }
                }
            }
        }
        sender.close("eof", "").await;
    };
    let downstream = async {
        while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
            if write.write_all(&bytes).await.is_err() {
                break;
            }
        }
        let _ = write.shutdown().await;
    };
    tokio::join!(upstream, downstream);
}

type Refused = (&'static str, String);

/// A live, authenticated link to `peer`: the cached one, else a new dial and `auth`.
async fn link_to(
    dialer: &Arc<Dialer>,
    peer: &str,
    write: &mut tokio::net::unix::OwnedWriteHalf,
) -> Result<Arc<Link>, Refused> {
    if let Some(link) = dialer.links.lock().expect("links").get(peer).filter(|l| !l.is_closed()).cloned() {
        return Ok(link);
    }
    let signaling = dialer
        .signaling
        .borrow()
        .clone()
        .ok_or(("offline", "this Mac is not connected to the cmux service yet".to_owned()))?;
    let identity = dialer
        .identity
        .borrow()
        .clone()
        .ok_or(("unavailable", "the cmux app has not given hostd this Mac's identity key".to_owned()))?;
    let (ice_servers, _) = dialer.ice.servers().await;
    let options = DialOptions { ice_servers, timeout: DIAL_TIMEOUT, ..DialOptions::default() };
    let connected = cmux_mobile_link::dial::connect(
        &signaling,
        peer,
        TransportKind::WireGuard,
        &options,
        LinkConfig::default(),
    )
    .await
    .map_err(|error| match error.to_string() {
        text if text.contains("offline") => ("offline", "that machine is offline".to_owned()),
        text => ("unreachable", text),
    })?;
    let link = Arc::new(connected.link);
    authenticate(&link, dialer, &identity, peer, write).await?;
    dialer.links.lock().expect("links").insert(peer.to_owned(), Arc::clone(&link));
    Ok(link)
}

/// `auth` as a Mac: the peer's challenge signed with this Mac's identity key.
async fn authenticate(
    link: &Link,
    dialer: &Dialer,
    identity: &MacIdentity,
    peer: &str,
    write: &mut tokio::net::unix::OwnedWriteHalf,
) -> Result<(), Refused> {
    let closed = |what: &str| ("closed", format!("the link closed during {what}"));
    let mut channel = link
        .open(
            "auth",
            json!({"identityKey": identity.public_key(), "approvalKey": "", "name": dialer.device_name, "kind": "mac"}),
        )
        .await
        .map_err(|_| closed("auth"))?;
    let challenge = next_reply(&mut channel).await?;
    let nonce = challenge.get("challenge").and_then(Value::as_str).unwrap_or_default();
    if challenge.get("mac").and_then(Value::as_str) != Some(peer) {
        return Err(("bad_reply", "that machine answered for another device id".to_owned()));
    }
    let message =
        crate::pairing::challenge_message(peer, &dialer.device_id, nonce, identity.public_key(), "", "pair");
    let signature = identity.sign(&message).ok_or(("unavailable", "could not sign".to_owned()))?;
    channel
        .send(Bytes::from(json!({"signature": signature}).to_string()))
        .await
        .map_err(|_| closed("auth"))?;
    loop {
        let answer = next_reply(&mut channel).await?;
        if answer.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(());
        }
        if answer.get("pending").and_then(Value::as_bool) == Some(true) {
            // The CLI says "Allow it on that Mac or on your phone" while it waits.
            let _ = reply(write, json!({"pending": true})).await;
            continue;
        }
        return Err(("bad_reply", answer.to_string()));
    }
}

/// The next JSON reply on `auth`, or why there is none.
async fn next_reply(channel: &mut cmux_mobile_link::Channel) -> Result<Value, Refused> {
    match tokio::time::timeout(AUTH_TIMEOUT, channel.recv()).await {
        Ok(Some(ChannelEvent::Data(bytes))) => {
            serde_json::from_slice::<Value>(&bytes).map_err(|_| ("bad_reply", "not JSON".to_owned()))
        }
        Ok(Some(ChannelEvent::Closed(info))) => Err((close_code(&info.code), info.reason)),
        Ok(None) => Err(("closed", "the link closed".to_owned())),
        Err(_) => Err(("timeout", "nobody answered on that machine".to_owned())),
    }
}

/// The peer's close code, as one of ours (a static str for the reply).
fn close_code(code: &str) -> &'static str {
    match code {
        "denied" => "denied",
        "unpaired" => "unpaired",
        "rate_limited" => "rate_limited",
        "timeout" => "timeout",
        "unavailable" => "unavailable",
        "bad_request" => "bad_request",
        _ => "refused",
    }
}

/// For tests: whether `path` is where the CLI looks for daemon socket `daemon`.
pub fn check_socket_path(daemon: &str, expected: &str) -> Result<()> {
    let got = socket_path(Path::new(daemon));
    if got != Path::new(expected) {
        bail!("{} != {expected}", got.display());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_link_socket_sits_beside_the_daemon_socket() {
        check_socket_path("/tmp/cmux-tui-501/main.sock", "/tmp/cmux-tui-501/main.link.sock").unwrap();
        check_socket_path("/tmp/cmux-tui-501/cmux-next-dev.sock", "/tmp/cmux-tui-501/cmux-next-dev.link.sock")
            .unwrap();
    }

    #[test]
    fn peer_close_codes_map_to_our_answers() {
        assert_eq!(close_code("denied"), "denied");
        assert_eq!(close_code("not_granted"), "refused");
    }
}

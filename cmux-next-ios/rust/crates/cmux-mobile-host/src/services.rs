//! Link services (PROTOCOL.md "Services"). Default deny: a service not
//! listed here is closed with `unknown_service`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::{ChannelEvent, IncomingChannel};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::chief_policy::ChiefPolicy;
use crate::config::{AcpmuxTarget, ServiceConfig};
use crate::control;
use crate::policy::{DaemonPolicy, MAXIMUM_LINE_BYTES, Verdict};

/// Who opened the channel.
#[derive(Debug, Clone)]
pub struct Peer {
    pub device_id: String,
    /// The link session (a UUID): one `upload` folder per session.
    pub session_id: String,
    /// The link's media lane (browser video as RTP: a WebRTC track or UDP
    /// inside the WireGuard tunnel), if the
    /// phone and this Mac negotiated one.
    pub video: Option<cmux_mobile_link::media::VideoOut>,
}

/// Serve one incoming channel to completion. With pairing on, only `auth`
/// is served until the link's phone proved keys the Mac approved; a channel
/// opened after `auth` waits for it.
pub async fn serve(
    config: Arc<ServiceConfig>,
    peer: Peer,
    link: Arc<crate::pairing::LinkAuth>,
    incoming: IncomingChannel,
) {
    let IncomingChannel { service, args, lane, channel } = incoming;
    let (sender, mut receiver) = channel.split();
    tracing::info!(
        service,
        channel = sender.id(),
        ?lane,
        own_stream = sender.on_input_stream(),
        peer = peer.device_id,
        "channel opened"
    );
    let gate = if config.pairing.is_none() || service == "auth" {
        crate::pairing::Gate::Paired
    } else {
        link.gate().await
    };
    let result = match service.as_str() {
        "auth" => crate::pairing::serve(
            config.pairing.as_ref(),
            &peer.device_id,
            &link,
            &args,
            &sender,
            &mut receiver,
        )
        .await
        .map_err(|(code, reason)| Refusal::new(code, reason)),
        _ if gate == crate::pairing::Gate::Busy => {
            Err(Refusal::new("busy", "too many channels wait for this iPhone's pairing"))
        }
        _ if gate != crate::pairing::Gate::Paired => {
            Err(Refusal::new("unpaired", "pair this iPhone with the Mac first (auth)"))
        }
        "echo" => echo(&sender, receiver).await,
        "daemon" => daemon(&config, &peer, &args, &sender, receiver).await,
        "chief" => chief(&config, &peer, &sender, receiver).await,
        "acpmux" => acpmux(&config, &peer.device_id, &sender, receiver).await,
        "file" => file(&config, &args, &sender).await,
        "upload" => upload(&config, &peer, &args, &sender, receiver).await,
        "version" => version(&config, &sender).await,
        "browser" => crate::browser::serve(&config.browser, &*config, &peer, &args, &sender, receiver).await,
        "surface" => crate::surface::serve(&config.surface, &*config, &peer, &args, &sender, receiver).await,
        _ => Err(Refusal::new("unknown_service", format!("no service {service}"))),
    };
    match result {
        Ok(()) => sender.close("eof", "").await,
        Err(refusal) => {
            tracing::info!(
                service,
                code = refusal.code,
                reason = refusal.reason,
                "channel refused or failed"
            );
            sender.close(refusal.code, &refusal.reason).await;
        }
    }
}

/// Closes `incoming` at once with `code` (the accept loop's own refusals).
pub async fn refuse(incoming: IncomingChannel, code: &'static str, reason: &str) {
    let (sender, _receiver) = incoming.channel.split();
    tracing::info!(service = incoming.service, code, reason, "channel refused");
    sender.close(code, reason).await;
}

#[derive(Debug)]
pub struct Refusal {
    pub code: &'static str,
    pub reason: String,
}

impl Refusal {
    pub(crate) fn new(code: &'static str, reason: impl Into<String>) -> Self {
        Self { code, reason: reason.into() }
    }
}

/// What the Mac side runs, so a phone can tell an outdated Mac (whose
/// hostd refuses this service with `unknown_service`) and say so.
pub const LINK_PROTOCOL: u32 = 2;

/// The `version` service's `capabilities` (PROTOCOL.md "Services").
pub const CAPABILITIES: [&str; 1] = ["removal-v1"];
/// Added to [`CAPABILITIES`] when this Mac can stream browser tabs (`browser`).
pub const BROWSER_STREAM: &str = "browser-stream-v1";
/// With [`BROWSER_STREAM`]: `browser {"video": "track"}` carries the page's
/// video on the link's media lane when the link has one.
pub const BROWSER_VIDEO_TRACK: &str = "browser-video-track-v1";
/// Added when this Mac streams its phone tabs' simulators (`surface`), with
/// `video: "track"` as for browser tabs.
pub const SURFACE_STREAM: &str = "surface-stream-v1";

/// What this host does that a phone may rely on.
pub fn capabilities(config: &ServiceConfig) -> Vec<&'static str> {
    let mut out = CAPABILITIES.to_vec();
    if config.browser.available() {
        out.push(BROWSER_STREAM);
        out.push(BROWSER_VIDEO_TRACK);
    }
    if config.surface.available() {
        out.push(SURFACE_STREAM);
    }
    out
}

async fn version(config: &ServiceConfig, sender: &ChannelSender) -> Result<(), Refusal> {
    let reply = serde_json::json!({
        "hostd": env!("CARGO_PKG_VERSION"),
        // 2: control frames ahead of data, any frame counts as life, the
        // reader never stalls on one full channel, the `version` service.
        "link": LINK_PROTOCOL,
        // What this host does that a phone may rely on. `removal-v1`: once its owner
        // removes this Mac (4002 `removed`) it stays off until allowed again on the Mac.
        // `browser-stream-v1`: it streams browser tabs (`browser`).
        "capabilities": capabilities(config),
    });
    let _ = sender.send(Bytes::from(reply.to_string())).await;
    Ok(())
}

async fn echo(sender: &ChannelSender, mut receiver: ChannelReceiver) -> Result<(), Refusal> {
    while let Some(ChannelEvent::Data(bytes)) = receiver.recv().await {
        if sender.send(bytes).await.is_err() {
            break;
        }
    }
    Ok(())
}

fn valid_session_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// The filter a spliced daemon line passes through.
#[derive(Clone)]
enum LinePolicy {
    Daemon(DaemonPolicy),
    Chief(ChiefPolicy),
}

impl LinePolicy {
    /// The verdict, and for `Forward` the exact bytes to send: the daemon
    /// lane sends the line as it came; the Chief lane sends the object it
    /// checked, serialized again, so a duplicate key cannot mean one thing to
    /// the filter and another to the owner.
    fn evaluate(&self, line: &[u8]) -> (Verdict, Option<Vec<u8>>) {
        match self {
            Self::Daemon(policy) => (policy.evaluate(line), None),
            Self::Chief(policy) => {
                let verdict = policy.evaluate(line);
                let canonical = matches!(verdict, Verdict::Forward)
                    .then(|| {
                        serde_json::from_slice::<Value>(line).ok().and_then(|v| serde_json::to_vec(&v).ok())
                    })
                    .flatten();
                (verdict, canonical)
            }
        }
    }

    /// The daemon line the phone gets (`line` ends with its newline), or
    /// nothing. The daemon lane forwards every line as it came.
    fn reply(&self, line: Vec<u8>) -> Option<Vec<u8>> {
        match self {
            Self::Daemon(_) => Some(line),
            Self::Chief(policy) => {
                let body = line.strip_suffix(b"\n").unwrap_or(&line);
                let mut out = policy.filter_reply(body)?;
                out.push(b'\n');
                Some(out)
            }
        }
    }
}

/// `daemon`: splice to the cmux-tui session socket, filtering every phone
/// request line through [`DaemonPolicy`]. The Chief's conversation owner
/// (`cmux-chief-*`) is never reachable this way: only through `chief`.
async fn daemon(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let named = args.get("session").and_then(Value::as_str);
    let session = named.unwrap_or(&config.default_session);
    // The Chief owner is reachable only through `chief` (the default macOS
    // volume is case-insensitive, hence the lowercase test and the path check).
    if !valid_session_name(session) || session.to_ascii_lowercase().starts_with("cmux-chief-") {
        return Err(Refusal::new("bad_request", "invalid session name"));
    }
    // Supervised by the app: only the app's own daemon, never another channel's or tag's.
    if config.default_socket.is_some() && named.is_some_and(|name| name != config.default_session) {
        return Err(Refusal::new("forbidden", "only this app's session is shared"));
    }
    let path = match (named, &config.default_socket) {
        (None, Some(socket)) => socket.clone(),
        _ => config.tui_socket_dir.join(format!("{session}.sock")),
    };
    if let Some(chief) = &config.chief_socket
        && path.to_string_lossy().eq_ignore_ascii_case(&chief.to_string_lossy())
    {
        return Err(Refusal::new("bad_request", "invalid session name"));
    }
    splice(
        &path,
        session,
        LinePolicy::Daemon(
            DaemonPolicy::new(&peer.device_id).with_agent_tab_host(config.agent_tab_host.clone()),
        ),
        config.pairing.as_ref().map(|pairing| std::sync::Arc::clone(&pairing.spent_replies)),
        sender,
        receiver,
    )
    .await
}

/// `chief`: splice to the Chief's conversation owner (the cmux-tui session
/// of the Mac's Chief home), every line both ways through [`ChiefPolicy`].
async fn chief(
    config: &ServiceConfig,
    peer: &Peer,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let Some(path) = config.chief_socket.clone() else {
        return Err(Refusal::new("unavailable", "Chief is not set up on this Mac"));
    };
    // Paired: this phone's question answers need its signature (chief_answers.rs).
    let policy = match &config.pairing {
        Some(pairing) => ChiefPolicy::signed(crate::chief_answers::AnswerCheck {
            mac: pairing.mac_device_id.clone(),
            phone: peer.device_id.clone(),
            trust: pairing.trust.clone(),
            spent: std::sync::Arc::clone(&pairing.spent_answers),
        }),
        None => ChiefPolicy::new(),
    };
    splice(&path, "chief", LinePolicy::Chief(policy), None, sender, receiver).await
}

/// Splices one phone channel to a daemon socket. Responses and refusals
/// reach the phone as whole lines, never interleaved.
async fn splice(
    path: &Path,
    label: &str,
    policy: LinePolicy,
    spent_replies: Option<std::sync::Arc<crate::mailbox::SpentReplies>>,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    // The daemon lane: a phone's new terminal opens in its pane's folder (with_pane_folder).
    let terminal_folders = matches!(policy, LinePolicy::Daemon(_)).then(|| path.to_path_buf());
    let reply_phone = match &policy {
        LinePolicy::Daemon(daemon) => Some(daemon.device_id().to_owned()),
        LinePolicy::Chief(_) => None,
    };
    let socket = UnixStream::connect(path)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("cmux-tui session {label}: {e}")))?;
    let (daemon_read, mut daemon_write) = socket.into_split();
    let (lines_tx, mut lines_rx) = mpsc::channel::<Vec<u8>>(256);
    // The daemon lane: the phone's terminal size claims, released when it
    // leaves on purpose (size_release.rs).
    let claims = terminal_folders.is_some();
    let _active = claims.then(crate::size_release::ActiveSplice::begin);
    let pending = Arc::new(crate::size_release::PendingReleases::default());

    // Daemon → phone, whole lines.
    let daemon_lines = lines_tx.clone();
    let reply_policy = policy.clone();
    let answers = Arc::clone(&pending);
    let mut from_daemon = tokio::spawn(async move {
        let mut reader = BufReader::with_capacity(64 * 1024, daemon_read);
        loop {
            let mut line = Vec::new();
            match reader.read_until(b'\n', &mut line).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {
                    // hostd's own releases: answered to hostd, not the phone.
                    if answers.answer(&line) {
                        continue;
                    }
                    let Some(line) = reply_policy.reply(line) else { continue };
                    if daemon_lines.send(line).await.is_err() {
                        return;
                    }
                }
            }
        }
    });

    // Phone → daemon, filtered.
    let refusals = lines_tx;
    let releases = Arc::clone(&pending);
    let mut stopping = crate::size_release::stopping();
    let mut to_daemon = tokio::spawn(async move {
        let mut pending: Vec<u8> = Vec::new();
        let mut sized = crate::size_release::SizeClaims::default();
        loop {
            let event = tokio::select! {
                event = receiver.recv() => event,
                // hostd is stopping (iPhone connections off, the app quitting).
                () = async { drop(stopping.wait_for(|stopping| *stopping).await) }, if claims => {
                    release_claims(&sized, &releases, &mut daemon_write, crate::size_release::ReleaseReason::Stopping).await;
                    return;
                }
            };
            let bytes = match event {
                Some(ChannelEvent::Data(bytes)) => bytes,
                Some(ChannelEvent::Closed(info)) => {
                    if claims && let Some(reason) = crate::size_release::ReleaseReason::for_close(&info) {
                        release_claims(&sized, &releases, &mut daemon_write, reason).await;
                    }
                    return;
                }
                None => return,
            };
            pending.extend_from_slice(&bytes);
            while let Some(newline) = pending.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = pending.drain(..=newline).collect();
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let (verdict, canonical) = policy.evaluate(&line);
                if let Some(canonical) = canonical {
                    line = canonical;
                }
                // The daemon lane: the phone's objects confirmed by the Mac's own state.
                let verdict = match (&terminal_folders, verdict) {
                    (Some(path), Verdict::Forward) => owned_check(path, line.clone(), Verdict::Forward).await,
                    (Some(path), Verdict::Rewrite(checked)) => {
                        owned_check(path, checked.clone(), Verdict::Rewrite(checked)).await
                    }
                    (_, verdict) => verdict,
                };
                // A reply to a terminal notification: hostd answers it itself
                // (the daemon has no such command), into that terminal only.
                if matches!(verdict, Verdict::Forward)
                    && let (Some(path), Some(phone)) = (&terminal_folders, &reply_phone)
                    && is_notification_reply(&line)
                {
                    let mut answer = crate::mailbox_apply::answer_notification_reply(
                        path,
                        phone,
                        spent_replies.as_deref(),
                        &line,
                    )
                    .await
                    .into_bytes();
                    answer.push(b'\n');
                    if refusals.send(answer).await.is_err() {
                        return;
                    }
                    continue;
                }
                match verdict {
                    Verdict::Forward => {
                        if let Some(path) = &terminal_folders {
                            line = with_pane_folder(path, line).await;
                        }
                        if claims {
                            sized.observe(&line);
                        }
                        line.push(b'\n');
                        if daemon_write.write_all(&line).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Rewrite(mut line) => {
                        if let Some(path) = &terminal_folders {
                            line = with_pane_folder(path, line).await;
                        }
                        if claims {
                            sized.observe(&line);
                        }
                        line.push(b'\n');
                        if daemon_write.write_all(&line).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Refuse(answer) => {
                        let mut answer = answer.into_bytes();
                        answer.push(b'\n');
                        if refusals.send(answer).await.is_err() {
                            return;
                        }
                    }
                }
            }
            if pending.len() > MAXIMUM_LINE_BYTES {
                let mut answer =
                    crate::policy::error_line(None, "too_large", "request exceeds 4 MiB").into_bytes();
                answer.push(b'\n');
                let _ = refusals.send(answer).await;
                return;
            }
        }
    });

    loop {
        tokio::select! {
            line = lines_rx.recv() => match line {
                Some(line) => {
                    if sender.send(Bytes::from(line)).await.is_err() {
                        // The phone is gone (its close frame, a removed phone). Its
                        // close reaches the phone-to-daemon task, which releases its
                        // sizes: let that finish (bounded) instead of aborting it,
                        // or the daemon reads end of file first and holds the grid.
                        if claims {
                            let _ = tokio::time::timeout(
                                crate::size_release::RELEASE_WAIT + std::time::Duration::from_millis(300),
                                async {
                                    loop {
                                        tokio::select! {
                                            _ = &mut to_daemon => return,
                                            line = lines_rx.recv() => if line.is_none() { return },
                                        }
                                    }
                                },
                            )
                            .await;
                        }
                        break;
                    }
                }
                None => break,
            },
            _ = &mut to_daemon => {
                // The phone closed or broke policy; drain what the daemon
                // already answered, briefly, then end.
                while let Ok(Some(line)) = tokio::time::timeout(std::time::Duration::from_millis(200), lines_rx.recv()).await {
                    let _ = sender.send(Bytes::from(line)).await;
                }
                break;
            }
            _ = &mut from_daemon => {
                while let Ok(line) = lines_rx.try_recv() {
                    let _ = sender.send(Bytes::from(line)).await;
                }
                break;
            }
        }
    }
    to_daemon.abort();
    from_daemon.abort();
    Ok(())
}

/// Whether `line` is a `notification-reply` request.
fn is_notification_reply(line: &[u8]) -> bool {
    serde_json::from_slice::<Value>(line)
        .ok()
        .is_some_and(|v| v.get("cmd").and_then(Value::as_str) == Some("notification-reply"))
}

/// Releases every terminal size the phone claimed on this channel and waits
/// (at most `RELEASE_WAIT`) for the daemon's answers, keeping the socket open
/// meanwhile: an end of file the daemon read before a release would be a
/// dropped view, which holds the grid.
async fn release_claims(
    claims: &crate::size_release::SizeClaims,
    pending: &crate::size_release::PendingReleases,
    daemon: &mut tokio::net::unix::OwnedWriteHalf,
    reason: crate::size_release::ReleaseReason,
) {
    if claims.is_empty() {
        return;
    }
    let lines = claims.release_lines();
    tracing::info!(?reason, terminals = lines.len(), "releasing the phone's terminal sizes");
    let mut batch = Vec::new();
    for (id, line) in lines {
        pending.add(id);
        batch.extend_from_slice(&line);
        batch.push(b'\n');
    }
    if daemon.write_all(&batch).await.is_err() {
        return;
    }
    pending.wait(crate::size_release::RELEASE_WAIT).await;
}

/// The acpmux WebSocket address and token.
fn acpmux_endpoint(target: &AcpmuxTarget) -> Result<(String, Option<String>), Refusal> {
    match target {
        AcpmuxTarget::Fixed { url, token } => Ok((url.clone(), token.clone())),
        AcpmuxTarget::Supplied(endpoint) => endpoint
            .borrow()
            .clone()
            .ok_or_else(|| Refusal::new("unavailable", "acpmux is not running in the app")),
        AcpmuxTarget::Home(home) => {
            let path = home.join("config.json");
            let text = std::fs::read_to_string(&path)
                .map_err(|e| Refusal::new("unavailable", format!("acpmux config {}: {e}", path.display())))?;
            let config: Value = serde_json::from_str(&text)
                .map_err(|_| Refusal::new("unavailable", "acpmux config is not JSON"))?;
            let websocket = config
                .get("websocket")
                .ok_or_else(|| Refusal::new("unavailable", "acpmux has no web listener"))?;
            let listen = websocket
                .get("listen")
                .and_then(Value::as_str)
                .ok_or_else(|| Refusal::new("unavailable", "acpmux web listener has no address"))?;
            let token = websocket.get("token").and_then(Value::as_str).map(str::to_owned);
            Ok((format!("ws://{listen}/"), token))
        }
    }
}

/// How long the `acpmux` service waits for the app to report a new endpoint.
const ACPMUX_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

pub(crate) type AcpmuxSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Opens the acpmux loopback WebSocket with its bearer token.
pub(crate) async fn connect_acpmux(target: &AcpmuxTarget) -> Result<AcpmuxSocket, Refusal> {
    connect_acpmux_as(target, None).await
}

/// `connect_acpmux` with `credential` (a phone's own acpmux credential) in place of the
/// dashboard token.
async fn connect_acpmux_as(target: &AcpmuxTarget, credential: Option<&str>) -> Result<AcpmuxSocket, Refusal> {
    let (url, token) = acpmux_endpoint(target)?;
    let token = credential.map(str::to_owned).or(token);
    let mut request = url.into_client_request().map_err(|e| Refusal::new("unavailable", e.to_string()))?;
    if !request.uri().host().is_some_and(is_loopback_host) {
        return Err(Refusal::new("forbidden", "acpmux listener is not on loopback"));
    }
    if let Some(token) = token {
        request.headers_mut().insert(
            "authorization",
            format!("Bearer {token}").parse().map_err(|_| Refusal::new("unavailable", "bad acpmux token"))?,
        );
    }
    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .map_err(|e| Refusal::new("unavailable", format!("acpmux: {e}")))?;
    Ok(socket)
}

/// `acpmux`: splice to the acpmux loopback WebSocket. One link data frame
/// carries one WebSocket text message in each direction.
///
/// A phone the app gave its own acpmux credential (`control::phone_credential`) connects
/// with it, so acpmux knows which phone it is (still a Web connection, with every Web
/// rule). What `acpmux_policy` refuses then goes on marked, and acpmux runs it only when
/// that phone's Full-access setting (Settings > Devices on the Mac, off by default)
/// covers it. Without a credential, or when acpmux refuses it, the dashboard token and
/// the refusal here stay as they were.
async fn acpmux(
    config: &ServiceConfig,
    phone: &str,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    let credential = control::phone_credential(phone);
    let own = match credential.as_deref() {
        Some(credential) => connect_acpmux_as(&config.acpmux, Some(credential)).await.ok(),
        None => None,
    };
    let as_phone = own.is_some();
    let socket = match own {
        Some(socket) => socket,
        None => connect_dashboard(&config.acpmux).await?,
    };
    let (mut ws_sink, mut ws_source) = socket.split();
    let mut message = MessageAssembler::default();
    // A second connection of hostd's own, for `_acpmux/info` (the mode check).
    let mut side: Option<AcpmuxSocket> = None;
    loop {
        tokio::select! {
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    let Some(text) = message.push(&bytes)? else { continue };
                    // An agent a phone drives stays in a mode that asks
                    // (`acpmux_policy`): a refused mode set is answered here.
                    let refused = match crate::acpmux_policy::refusal(&text) {
                        Some(answer) => Some(answer),
                        None => match crate::acpmux_policy::controlled_session(&text) {
                            Some((id, session)) => {
                                let mode = current_mode(&config.acpmux, &mut side, &session).await;
                                crate::acpmux_policy::mode_refusal(&id, mode.as_deref())
                            }
                            None => None,
                        },
                    };
                    // On the phone's own credential acpmux decides by its Full-access setting.
                    let (text, refused) = match (refused, as_phone) {
                        (Some(answer), true) => match crate::acpmux_policy::marked(&text) {
                            Some(marked) => (marked, None),
                            None => (text, Some(answer)),
                        },
                        (refused, _) => (text, refused),
                    };
                    if let Some(answer) = refused {
                        if sender.send(Bytes::from(answer.into_bytes())).await.is_err() {
                            break;
                        }
                        continue;
                    }
                    if ws_sink.send(Message::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                _ => break,
            },
            message = ws_source.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    if sender.send(Bytes::copy_from_slice(text.as_bytes())).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Binary(bytes))) => {
                    if sender.send(bytes).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }
    let _ = ws_sink.close().await;
    Ok(())
}

/// The acpmux WebSocket on the dashboard token. Supervised, the app's acpmux may have
/// restarted on another port: ask the app once and retry with what it sends.
async fn connect_dashboard(target: &AcpmuxTarget) -> Result<AcpmuxSocket, Refusal> {
    match (connect_acpmux(target).await, target) {
        (Ok(socket), _) => Ok(socket),
        (Err(refusal), AcpmuxTarget::Supplied(endpoint)) if refusal.code == "unavailable" => {
            let mut endpoint = endpoint.clone();
            endpoint.borrow_and_update();
            control::emit(&control::Event::NeedAcpmux);
            let _ = tokio::time::timeout(ACPMUX_WAIT, endpoint.changed()).await;
            connect_acpmux(target).await
        }
        (Err(refusal), _) => Err(refusal),
    }
}

/// A session's current mode (`_acpmux/info` `currentModeId`) over hostd's own
/// side connection, opened on first use; None when acpmux does not say in 5 s
/// (acpmux's own remote guard then decides alone).
async fn current_mode(
    target: &AcpmuxTarget,
    side: &mut Option<AcpmuxSocket>,
    session: &str,
) -> Option<String> {
    let ask = async {
        if side.is_none() {
            *side = Some(connect_acpmux(target).await.ok()?);
        }
        let socket = side.as_mut()?;
        let request = serde_json::json!({"jsonrpc": "2.0", "id": "cmux-mobile-mode", "method": "_acpmux/info", "params": {"sessionId": session}});
        socket.send(Message::Text(request.to_string().into())).await.ok()?;
        while let Some(Ok(frame)) = socket.next().await {
            let Message::Text(text) = frame else { continue };
            let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
            if reply.get("id") != Some(&serde_json::json!("cmux-mobile-mode")) {
                continue;
            }
            let result = reply.get("result")?;
            return result
                .get("currentModeId")
                .or_else(|| result.pointer("/modes/currentModeId"))
                .and_then(Value::as_str)
                .map(str::to_owned);
        }
        None
    };
    let mode = tokio::time::timeout(std::time::Duration::from_secs(5), ask).await.ok().flatten();
    if mode.is_none() {
        // A broken or slow side connection is opened again next time.
        *side = None;
    }
    mode
}

/// The largest acpmux message a phone may send (a prompt with images).
pub const MAXIMUM_ACPMUX_MESSAGE_BYTES: usize = 32 * 1024 * 1024;

/// Joins the link data frames of one acpmux message. The link splits a
/// write above 256 KiB into several frames (PROTOCOL.md "Link"), so a
/// prompt carrying an image arrives in pieces; a message is complete when
/// the bytes so far parse as one JSON value.
#[derive(Default)]
pub struct MessageAssembler {
    pending: Vec<u8>,
}

impl MessageAssembler {
    /// The complete message, or None while more frames are needed.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Option<String>, Refusal> {
        self.pending.extend_from_slice(bytes);
        if self.pending.len() > MAXIMUM_ACPMUX_MESSAGE_BYTES {
            return Err(Refusal::new("too_large", "acpmux message exceeds 32 MiB"));
        }
        match serde_json::from_slice::<serde::de::IgnoredAny>(&self.pending) {
            Ok(_) => {
                let text = String::from_utf8(std::mem::take(&mut self.pending))
                    .map_err(|_| Refusal::new("bad_request", "acpmux frames are UTF-8 JSON"))?;
                Ok(Some(text))
            }
            Err(error) if error.is_eof() => Ok(None),
            Err(_) => Err(Refusal::new("bad_request", "acpmux frames are UTF-8 JSON")),
        }
    }
}

fn is_loopback_host(host: &str) -> bool {
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "localhost" || host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// Resolve `requested` inside one of `roots`; symlinks may not escape.
pub fn confine(roots: &[PathBuf], requested: &Path) -> Result<PathBuf, Refusal> {
    if roots.is_empty() {
        return Err(Refusal::new("forbidden", "no workspace roots are shared"));
    }
    if !requested.is_absolute() {
        return Err(Refusal::new("bad_request", "path must be absolute"));
    }
    let resolved = std::fs::canonicalize(requested).map_err(|_| Refusal::new("not_found", "no such file"))?;
    let inside = roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .any(|root| resolved.starts_with(&root));
    if !inside {
        return Err(Refusal::new("forbidden", "path is outside the workspace roots"));
    }
    Ok(resolved)
}

/// Largest file the `file` service streams (artifact previews, not transfers).
pub const MAXIMUM_FILE_BYTES: u64 = 64 << 20;

/// The open file's real path (`F_GETPATH`) must still be inside a root.
#[cfg(target_vendor = "apple")]
fn confine_open(roots: &[PathBuf], file: &tokio::fs::File) -> Result<(), Refusal> {
    use std::os::fd::AsRawFd;
    let mut buffer = vec![0u8; libc::PATH_MAX as usize];
    // SAFETY: the descriptor is open for the duration of the call and the buffer
    // holds PATH_MAX bytes, as F_GETPATH requires.
    let ok = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } != -1;
    if !ok {
        return Err(Refusal::new("forbidden", "cannot check the opened file"));
    }
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
    let opened = PathBuf::from(String::from_utf8_lossy(&buffer[..end]).into_owned());
    let inside = roots
        .iter()
        .filter_map(|root| std::fs::canonicalize(root).ok())
        .any(|root| opened.starts_with(&root));
    if inside { Ok(()) } else { Err(Refusal::new("forbidden", "path is outside the workspace roots")) }
}

/// Elsewhere hostd does not run (it serves Macs); the path check before the open stands alone.
#[cfg(not(target_vendor = "apple"))]
fn confine_open(_roots: &[PathBuf], _file: &tokio::fs::File) -> Result<(), Refusal> {
    Ok(())
}

/// The workspace folders a phone may read from: the folders of the tabs the
/// Mac's daemon lists, the same folders the app shares with phones for agent
/// chats (`_acpmux/workspace_roots_set`, agentcwd). A folder that is `/`, the
/// home folder or any ancestor of it is dropped, as acpmux drops it: a tab in
/// `~` must not open `~/.ssh` to a phone.
/// A tab's folder is its shell's last reported cwd (OSC 7), which any output
/// can set, so a folder inside a credential or settings tree of home
/// ([`SENSITIVE_HOME_TREES`]) is dropped too.
pub fn shareable_workspace_folders(folders: Vec<PathBuf>, home: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    for folder in folders {
        let sensitive = SENSITIVE_HOME_TREES.iter().any(|tree| folder.starts_with(home.join(tree)));
        if !home.starts_with(&folder) && !sensitive && !out.contains(&folder) {
            out.push(folder);
        }
    }
    out
}

/// Folders of home that are never shared as workspace folders, nor anything
/// inside them: keys, credentials, app data and settings (PR #22555 review).
pub const SENSITIVE_HOME_TREES: &[&str] =
    &[".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".config", ".password-store", "Library"];

/// `path` resolved and spelled as the filesystem stores it (on macOS, `F_GETPATH`:
/// the stored case and Unicode form), as acpmux's `fs_spelling` compares roots, so a
/// tab whose shell spelled home `/users/ME` is still home. None when it can't be opened.
pub fn stored_spelling(path: &Path) -> Option<PathBuf> {
    let canonical = std::fs::canonicalize(path).ok()?;
    #[cfg(target_vendor = "apple")]
    {
        use std::os::fd::AsRawFd;
        let file = std::fs::File::open(&canonical).ok()?;
        let mut buffer = vec![0u8; libc::PATH_MAX as usize];
        // SAFETY: F_GETPATH writes at most PATH_MAX bytes into `buffer`, which holds
        // PATH_MAX bytes, for a descriptor this function owns.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buffer.as_mut_ptr()) } != -1 {
            let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
            return Some(PathBuf::from(String::from_utf8_lossy(&buffer[..end]).into_owned()));
        }
    }
    Some(canonical)
}

/// `CMUX_MOBILE_FILE_ROOTS` (the Chat Folders) and the shareable workspace folders. Without a
/// home folder that resolves, no workspace folder is shared (one might be home).
pub fn shared_file_roots(file_roots: &[PathBuf], folders: Vec<PathBuf>, home: &Path) -> Vec<PathBuf> {
    let mut roots = file_roots.to_vec();
    let Some(home) = stored_spelling(home) else { return roots };
    let folders = folders.iter().filter_map(|f| stored_spelling(f)).collect();
    for folder in shareable_workspace_folders(folders, &home) {
        if !roots.contains(&folder) {
            roots.push(folder);
        }
    }
    roots
}

/// `file`: stream one regular file inside a workspace root, then close
/// with `eof`. The roots are the Chat Folders, then (only when the file is
/// outside them) the Mac's workspace folders as they are now.
async fn file(config: &ServiceConfig, args: &Value, sender: &ChannelSender) -> Result<(), Refusal> {
    let requested = args
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| Refusal::new("bad_request", "missing path"))?;
    let (resolved, roots) = match confine(&config.file_roots, Path::new(requested)) {
        Ok(resolved) => (resolved, config.file_roots.clone()),
        Err(refusal) if refusal.code == "forbidden" => {
            // No home folder or no daemon answer: only the Chat Folders (the refusal stands).
            let Some(home) = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from) else {
                return Err(refusal);
            };
            let folders = daemon_folders(config).await.unwrap_or_default();
            let roots = shared_file_roots(&config.file_roots, folders, &home);
            (confine(&roots, Path::new(requested))?, roots)
        }
        Err(refusal) => return Err(refusal),
    };
    // Non-blocking, so a FIFO inside a root cannot hold the open; the checks below
    // refuse anything that is not a regular file.
    let mut file = tokio::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&resolved)
        .await
        .map_err(|_| Refusal::new("not_found", "cannot open"))?;
    // A path component swapped for a symlink between the check and the open would
    // escape the roots: check again where the open descriptor really points.
    confine_open(&roots, &file)?;
    let metadata = file.metadata().await.map_err(|_| Refusal::new("not_found", "cannot stat"))?;
    if !metadata.is_file() {
        return Err(Refusal::new("bad_request", "not a regular file"));
    }
    if metadata.len() > MAXIMUM_FILE_BYTES {
        return Err(Refusal::new("too_large", "file is larger than 64 MiB"));
    }
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).await.map_err(|e| Refusal::new("io", e.to_string()))?;
        if read == 0 {
            return Ok(());
        }
        if sender.send(Bytes::copy_from_slice(&buffer[..read])).await.is_err() {
            return Ok(());
        }
    }
}

/// A file name a phone sent, made safe for a folder of this Mac: no path
/// separators, control characters or leading dots, at most 120 bytes; an
/// empty result is `attachment`.
pub fn safe_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or_default();
    let mapped: String =
        base.chars().map(|c| if c.is_control() || matches!(c, ':' | '/' | '\\') { '_' } else { c }).collect();
    let trimmed = mapped.trim().trim_start_matches(['.', ' ']);
    let mut out = String::new();
    for c in trimmed.chars() {
        if out.len() + c.len_utf8() > 120 {
            break;
        }
        out.push(c);
    }
    if out.is_empty() { "attachment".into() } else { out }
}

/// The folders of the tabs the daemon lists (`list-workspaces`), canonical.
async fn daemon_folders(config: &ServiceConfig) -> Result<Vec<PathBuf>, Refusal> {
    Ok(folders_in(&list_workspaces(&config.daemon_socket()).await?))
}

/// The tab folders in a `list-workspaces` reply, canonical.
fn folders_in(reply: &Value) -> Vec<PathBuf> {
    let data = reply.get("data").unwrap_or(reply);
    let mut folders = Vec::new();
    let empty = Vec::new();
    let list = |value: &Value, key: &str| value.get(key).and_then(Value::as_array).unwrap_or(&empty).clone();
    for workspace in list(data, "workspaces") {
        for screen in list(&workspace, "screens") {
            for pane in list(&screen, "panes") {
                for tab in list(&pane, "tabs") {
                    if let Some(cwd) = tab.get("cwd").and_then(Value::as_str)
                        && cwd.starts_with('/')
                        && let Ok(folder) = std::fs::canonicalize(cwd)
                        && !folders.contains(&folder)
                    {
                        folders.push(folder);
                    }
                }
            }
        }
    }
    folders
}

/// The address of every browser tab in a `list-workspaces` reply.
pub fn browser_urls_in(reply: &Value) -> Vec<String> {
    let data = reply.get("data").unwrap_or(reply);
    let empty = Vec::new();
    let list = |value: &Value, key: &str| value.get(key).and_then(Value::as_array).unwrap_or(&empty).clone();
    let mut urls = Vec::new();
    for workspace in list(data, "workspaces") {
        for screen in list(&workspace, "screens") {
            for pane in list(&screen, "panes") {
                for tab in list(&pane, "tabs") {
                    if tab.get("kind").and_then(Value::as_str) == Some("browser")
                        && let Some(url) = tab.get("url").and_then(Value::as_str)
                        && !url.is_empty()
                        && !urls.iter().any(|u| u == url)
                    {
                        urls.push(url.to_owned());
                    }
                }
            }
        }
    }
    urls
}

/// What the Mac shares with phones and what its browser tabs show, for the
/// `browser` service's address checks (`browser_policy.rs`), from one
/// `list-workspaces` answer. No answer (or no home folder): only the Chat
/// Folders, and no Mac pages.
impl crate::browser_policy::MacPages for ServiceConfig {
    fn view(&self) -> futures_util::future::BoxFuture<'_, crate::browser_policy::MacView> {
        Box::pin(async move {
            let reply = list_workspaces(&self.daemon_socket()).await.ok();
            let browser_urls = reply.as_ref().map(browser_urls_in).unwrap_or_default();
            let roots = match std::env::var_os("HOME").filter(|h| !h.is_empty()) {
                Some(home) => {
                    let folders = reply.as_ref().map(folders_in).unwrap_or_default();
                    shared_file_roots(&self.file_roots, folders, Path::new(&home))
                }
                None => self.file_roots.clone(),
            };
            crate::browser_policy::MacView { roots, browser_urls }
        })
    }
}

/// A phone tab is one this Mac's daemon lists now (`list-workspaces`); no
/// answer streams nothing.
impl crate::surface::SurfaceTabs for ServiceConfig {
    fn is_phone_tab(&self, surface: u64) -> futures_util::future::BoxFuture<'_, bool> {
        Box::pin(async move {
            // Page tabs read as their record (`conversation.page`) only for a client
            // that negotiated `page-tabs-v1`; without it every page tab reads `browser`.
            daemon_query(
                &self.daemon_socket(),
                b"{\"cmd\":\"set-client-info\",\"id\":\"cmux-mobile-surface-hello\",\"name\":\"cmux-mobile-host\",\"kind\":\"cli\",\"capabilities\":[\"conversation-tabs-v1\",\"page-tabs-v1\"]}\n{\"cmd\":\"list-workspaces\",\"id\":\"cmux-mobile-surface\"}\n",
                "cmux-mobile-surface",
            )
            .await
            .is_ok_and(|reply| crate::surface::phone_tab_in(&reply, surface))
        })
    }
}

/// The daemon at `path`'s `list-workspaces` reply (at most 5 s).
async fn list_workspaces(path: &Path) -> Result<Value, Refusal> {
    daemon_query(path, b"{\"cmd\":\"list-workspaces\",\"id\":\"cmux-mobile-upload\"}\n", "cmux-mobile-upload")
        .await
}

/// The daemon at `path`'s `list-personal` reply: the person's sidebar order and groups (at most 5 s).
async fn list_personal(path: &Path) -> Result<Value, Refusal> {
    daemon_query(
        path,
        b"{\"cmd\":\"list-personal\",\"id\":\"cmux-mobile-personal\"}\n",
        "cmux-mobile-personal",
    )
    .await
}

/// The verdict for a line the policy let through, once the Mac's own state
/// (read on a separate connection) confirms the phone's object
/// (`policy::ownership`); a refusal otherwise, or when the Mac cannot answer.
async fn owned_check(path: &Path, line: Vec<u8>, verdict: Verdict) -> Verdict {
    use crate::policy::{
        Ownership, is_pinned_workspace_tile, lists_workspace, not_owned, ownership, owns_group,
        owns_personal_workspace, registry_id,
    };
    let Some(what) = ownership(&line) else { return verdict };
    let owned = match &what {
        Ownership::PersonalWorkspace { session, key } => {
            list_workspaces(path).await.is_ok_and(|reply| owns_personal_workspace(&reply, session, key))
        }
        Ownership::PinnedWorkspaceTile { item } => {
            let request = b"{\"protocol\":\"cmux.protocol/2\",\"type\":\"request\",\"id\":\"cmux-mobile-layout\",\"operation\":\"sidebar_layout.get\",\"params\":{\"machine\":\"current\",\"session\":\"current\"}}\n";
            daemon_query(path, request, "cmux-mobile-layout")
                .await
                .is_ok_and(|reply| is_pinned_workspace_tile(&reply, item))
        }
        Ownership::OwnGroup { group } => match list_workspaces(path).await {
            Ok(tree) => match registry_id(&tree) {
                Some(registry) => {
                    list_personal(path).await.is_ok_and(|personal| owns_group(&personal, registry, group))
                }
                None => false,
            },
            Err(_) => false,
        },
        Ownership::PlaceWorkspace { workspace, group } => match list_workspaces(path).await {
            Ok(tree) if lists_workspace(&tree, workspace) => match (group, registry_id(&tree)) {
                (None, _) => true,
                (Some(group), Some(registry)) => {
                    list_personal(path).await.is_ok_and(|personal| owns_group(&personal, registry, group))
                }
                (Some(_), None) => false,
            },
            _ => false,
        },
    };
    if owned { verdict } else { Verdict::Refuse(not_owned(&line, &what)) }
}

/// One request on a fresh connection to the daemon socket, its reply (`id` matched).
async fn daemon_query(path: &Path, request: &[u8], id: &str) -> Result<Value, Refusal> {
    let unavailable = |e: &dyn std::fmt::Display| Refusal::new("unavailable", format!("cmux-tui: {e}"));
    let read = async {
        let socket = UnixStream::connect(&path).await.map_err(|e| unavailable(&e))?;
        let (read, mut write) = socket.into_split();
        write.write_all(request).await.map_err(|e| unavailable(&e))?;
        let mut reader = BufReader::new(read);
        loop {
            let mut line = Vec::new();
            if reader.read_until(b'\n', &mut line).await.map_err(|e| unavailable(&e))? == 0 {
                return Err(unavailable(&"closed"));
            }
            let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
            if value.get("id").and_then(Value::as_str) == Some(id) {
                return Ok(value);
            }
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), read)
        .await
        .map_err(|_| unavailable(&"timed out"))?
}

/// The folder a phone's new terminal in `pane` opens in, chosen by the Mac (a phone
/// never sends `cwd`): the folder of the pane's active tab, else another tab of that
/// pane, else of its workspace. None for no such tab, a folder that is gone, `/`, the
/// home folder or a folder above it (the daemon's default, home, then stands).
pub fn pane_folder(reply: &Value, pane: u64, home: Option<&Path>) -> Option<String> {
    let data = reply.get("data").unwrap_or(reply);
    let empty = Vec::new();
    let list = |value: &Value, key: &str| value.get(key).and_then(Value::as_array).unwrap_or(&empty).clone();
    let cwd = |tab: &Value| {
        tab.get("cwd").and_then(Value::as_str).filter(|c| c.starts_with('/')).map(str::to_owned)
    };
    for workspace in list(data, "workspaces") {
        let panes: Vec<Value> = list(&workspace, "screens").iter().flat_map(|s| list(s, "panes")).collect();
        let Some(target) = panes.iter().find(|p| p.get("id").and_then(Value::as_u64) == Some(pane)) else {
            continue;
        };
        let tabs = list(target, "tabs");
        let active =
            target.get("active_tab").and_then(Value::as_u64).and_then(|i| tabs.get(usize::try_from(i).ok()?));
        let chosen = active
            .and_then(cwd)
            .or_else(|| tabs.iter().find_map(cwd))
            .or_else(|| panes.iter().flat_map(|p| list(p, "tabs")).find_map(|t| cwd(&t)))?;
        let folder = std::fs::canonicalize(&chosen).ok().filter(|f| f.is_dir())?;
        if folder.parent().is_none() || home.is_some_and(|h| h.starts_with(&folder)) {
            return None;
        }
        return folder.to_str().map(str::to_owned);
    }
    None
}

/// A phone's `new-tab` (no `cwd`: the policy refuses one) gets the Mac's choice of
/// folder for `pane` ([`pane_folder`]); any other line passes as is.
async fn with_pane_folder(path: &Path, line: Vec<u8>) -> Vec<u8> {
    let Ok(Value::Object(mut object)) = serde_json::from_slice::<Value>(&line) else { return line };
    if object.get("cmd").and_then(Value::as_str) != Some("new-tab") || object.contains_key("cwd") {
        return line;
    }
    let Some(pane) = object.get("pane").and_then(Value::as_u64) else { return line };
    let Ok(reply) = list_workspaces(path).await else { return line };
    let home = std::env::var_os("HOME").and_then(|h| std::fs::canonicalize(h).ok());
    let Some(folder) = pane_folder(&reply, pane, home.as_deref()) else { return line };
    object.insert("cwd".into(), Value::String(folder));
    serde_json::to_vec(&Value::Object(object)).unwrap_or(line)
}

/// The folder an `upload` writes to. With `cwd` (a folder of one of the
/// Mac's tabs, or inside a shared root): `<cwd>/.cmux/attachments/phone-<session>`,
/// next to acpmux's own attachments, so the agent of that workspace reads
/// it without leaving its folder. Without: `<uploads>/<session>`.
async fn upload_folder(config: &ServiceConfig, peer: &Peer, cwd: Option<&str>) -> Result<PathBuf, Refusal> {
    let session: String =
        peer.session_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(36).collect();
    if session.is_empty() {
        return Err(Refusal::new("bad_request", "no link session"));
    }
    let Some(cwd) = cwd else {
        let folder = config.uploads_dir.join(&session);
        create_private_dir(&config.uploads_dir)?;
        create_private_dir(&folder)?;
        return Ok(folder);
    };
    if !cwd.starts_with('/') || cwd.chars().any(char::is_control) {
        return Err(Refusal::new("bad_request", "cwd must be an absolute folder"));
    }
    let canonical = std::fs::canonicalize(cwd).map_err(|_| Refusal::new("not_found", "no such folder"))?;
    if !canonical.is_dir() {
        return Err(Refusal::new("bad_request", "cwd is not a folder"));
    }
    let in_roots = confine(&config.file_roots, &canonical).is_ok();
    if !in_roots && !daemon_folders(config).await?.contains(&canonical) {
        return Err(Refusal::new("forbidden", "cwd is not the folder of a tab on this Mac"));
    }
    let folder = canonical.join(".cmux").join("attachments").join(format!("phone-{session}"));
    std::fs::create_dir_all(&folder)
        .map_err(|e| Refusal::new("io", format!("cannot create the upload folder: {e}")))?;
    // `.cmux` or `attachments` may be a symlink out of the workspace.
    let resolved =
        std::fs::canonicalize(&folder).map_err(|_| Refusal::new("io", "upload folder vanished"))?;
    if !resolved.starts_with(&canonical) {
        return Err(Refusal::new("forbidden", "the upload folder leaves the workspace"));
    }
    Ok(resolved)
}

fn create_private_dir(path: &Path) -> Result<(), Refusal> {
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path) {
        Ok(()) => Ok(()),
        Err(e) => Err(Refusal::new("io", format!("cannot create {}: {e}", path.display()))),
    }
}

/// `<folder>/<name>`, or `<stem> 2.<ext>`, ... when that name is taken:
/// links `part` there without replacing anything.
fn publish_upload(folder: &Path, name: &str, part: &Path) -> Result<PathBuf, Refusal> {
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    for attempt in 1..=999 {
        let candidate = if attempt == 1 {
            folder.join(name)
        } else {
            folder.join(format!("{stem} {attempt}{extension}"))
        };
        match std::fs::hard_link(part, &candidate) {
            Ok(()) => {
                let _ = std::fs::remove_file(part);
                return Ok(candidate);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(Refusal::new("io", format!("cannot save the upload: {e}"))),
        }
    }
    Err(Refusal::new("io", "too many files with that name"))
}

/// `upload` `{name, size, cwd?}`: the phone sends exactly `size` bytes as
/// data frames; hostd writes them to a new file of the upload folder
/// ([`upload_folder`]) and answers one data frame `{"path","size"}`, then
/// closes with `eof`. A refusal is answered `{"error","message"}` before the
/// channel closes with that code. Nothing is overwritten, nothing is
/// executed, and a short, long or oversized upload leaves no file. `size`
/// may be a JSON number or a decimal string (the app's channel arguments
/// are strings).
async fn upload(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    match receive_upload(config, peer, args, receiver).await {
        Ok((path, size)) => {
            tracing::info!(size, phone = peer.device_id, "upload saved");
            let reply = serde_json::json!({"path": path.to_string_lossy(), "size": size}).to_string();
            let _ = sender.send(Bytes::from(reply)).await;
            Ok(())
        }
        Err(refusal) => {
            let reply = serde_json::json!({"error": refusal.code, "message": refusal.reason}).to_string();
            let _ = sender.send(Bytes::from(reply)).await;
            Err(refusal)
        }
    }
}

async fn receive_upload(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    mut receiver: ChannelReceiver,
) -> Result<(PathBuf, u64), Refusal> {
    let name = args
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| Refusal::new("bad_request", "missing name"))?;
    let size = match args.get("size") {
        Some(Value::Number(number)) => number.as_u64(),
        Some(Value::String(text)) => text.parse().ok(),
        _ => None,
    }
    .ok_or_else(|| Refusal::new("bad_request", "missing size"))?;
    if size > config.upload_max_bytes {
        return Err(Refusal::new(
            "too_large",
            format!("the file is larger than {} MB", config.upload_max_bytes / (1024 * 1024)),
        ));
    }
    let name = safe_file_name(name);
    let cwd = args.get("cwd").and_then(Value::as_str).filter(|cwd| !cwd.is_empty());
    let folder = upload_folder(config, peer, cwd).await?;
    let part = folder.join(format!(".{}.part", uuid::Uuid::new_v4()));
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&part)
        .await
        .map_err(|e| Refusal::new("io", format!("cannot create the upload: {e}")))?;
    let received = async {
        let mut received: u64 = 0;
        while received < size {
            match receiver.recv().await {
                Some(ChannelEvent::Data(bytes)) => {
                    received += bytes.len() as u64;
                    if received > size {
                        return Err(Refusal::new("bad_request", "more bytes than the declared size"));
                    }
                    file.write_all(&bytes).await.map_err(|e| Refusal::new("io", e.to_string()))?;
                }
                _ => return Err(Refusal::new("bad_request", "the upload ended early")),
            }
        }
        file.flush().await.map_err(|e| Refusal::new("io", e.to_string()))?;
        file.sync_all().await.map_err(|e| Refusal::new("io", e.to_string()))?;
        Ok(())
    }
    .await;
    drop(file);
    if let Err(refusal) = received {
        let _ = std::fs::remove_file(&part);
        return Err(refusal);
    }
    let path = publish_upload(&folder, &name, &part).inspect_err(|_| {
        let _ = std::fs::remove_file(&part);
    })?;
    Ok((path, size))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The daemon down: only the Chat Folders are shared and no Mac page loads.
    #[tokio::test]
    async fn with_no_daemon_the_browser_checks_fail_closed() {
        use crate::browser_policy::MacPages;
        let base = tempfile::tempdir().unwrap();
        let chat = base.path().join("chat");
        std::fs::create_dir_all(&chat).unwrap();
        let config = ServiceConfig {
            tui_socket_dir: base.path().to_path_buf(),
            default_session: "main".into(),
            default_socket: Some(base.path().join("gone.sock")),
            file_roots: vec![chat.clone()],
            acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: base.path().join("uploads"),
            upload_max_bytes: 1,
            chief_socket: None,
            browser: crate::browser::BrowserConfig::default(),
            surface: Default::default(),
        };
        let view = config.view().await;
        assert!(view.browser_urls.is_empty());
        assert_eq!(view.roots, vec![chat]);
    }

    #[test]
    fn the_macs_browser_tabs_are_listed() {
        let reply = serde_json::json!({"ok": true, "data": {"workspaces": [{"screens": [{"panes": [
            {"tabs": [{"surface": 9, "kind": "browser", "url": "file:///Users/me/a%20b.html"},
                      {"surface": 10, "kind": "pty", "url": "https://not-a-browser.example/", "cwd": "/Users/me"},
                      {"surface": 11, "kind": "browser", "url": ""}]},
            {"tabs": [{"surface": 12, "kind": "browser", "url": "https://cmux.com/"},
                      {"surface": 13, "kind": "browser", "url": "https://cmux.com/"}]}]}]}]}});
        assert_eq!(
            browser_urls_in(&reply),
            vec!["file:///Users/me/a%20b.html".to_owned(), "https://cmux.com/".into()]
        );
        assert!(browser_urls_in(&serde_json::json!({"ok": false})).is_empty());
    }

    /// End to end through a fake daemon: the phone's `new-tab` leaves with the pane's
    /// folder; a line that names one, or another command, is untouched.
    #[tokio::test]
    async fn a_phones_new_tab_line_gets_the_macs_folder() {
        let base = tempfile::tempdir().unwrap();
        let project = std::fs::canonicalize(base.path()).unwrap().join("project");
        std::fs::create_dir_all(&project).unwrap();
        let socket = base.path().join("d.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let folder = project.to_str().unwrap().to_owned();
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                use std::io::{BufRead, Write};
                let mut out = conn.try_clone().unwrap();
                let mut line = String::new();
                if std::io::BufReader::new(conn).read_line(&mut line).is_ok() {
                    let reply = serde_json::json!({"id": "cmux-mobile-upload", "data": {"workspaces": [{"screens": [{"panes": [
                        {"id": 3, "active_tab": 0, "tabs": [{"cwd": folder}]}]}]}]}});
                    let _ = writeln!(out, "{reply}");
                }
            }
        });
        let line =
            with_pane_folder(&socket, br#"{"id":1,"cmd":"new-tab","pane":3,"cols":80,"rows":24}"#.to_vec())
                .await;
        let sent: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(sent["cwd"].as_str(), project.to_str());
        let own = br#"{"id":2,"cmd":"new-tab","pane":3,"cwd":"/x"}"#.to_vec();
        assert_eq!(with_pane_folder(&socket, own.clone()).await, own);
        let other = br#"{"id":3,"cmd":"select-tab","surface":1}"#.to_vec();
        assert_eq!(with_pane_folder(&socket, other.clone()).await, other);
    }

    #[test]
    fn a_phones_new_terminal_opens_in_its_panes_folder() {
        let base = tempfile::tempdir().unwrap();
        let root = std::fs::canonicalize(base.path()).unwrap();
        let (project, other) = (root.join("project"), root.join("other"));
        std::fs::create_dir_all(&project).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        let reply = serde_json::json!({"data": {"workspaces": [{"screens": [{"panes": [
            {"id": 7, "active_tab": 1, "tabs": [{"cwd": other}, {"cwd": project}]},
            {"id": 8, "active_tab": 0, "tabs": [{"kind": "browser"}]},
            {"id": 9, "active_tab": 0, "tabs": [{"cwd": "/"}]},
        ]}]}]}});
        let at = |pane| pane_folder(&reply, pane, Some(&root.join("home")));
        // The active tab's folder; a pane without one takes the workspace's.
        assert_eq!(at(7).as_deref(), project.to_str());
        assert_eq!(at(8).as_deref(), other.to_str());
        // Never `/` or home (or above): the daemon's default stands.
        assert_eq!(at(9), None);
        assert_eq!(pane_folder(&reply, 7, Some(&project.join("me"))), None);
        // An unknown pane: nothing.
        assert_eq!(at(42), None);
    }

    #[test]
    fn browser_tabs_are_a_capability_only_with_a_browser_host() {
        let mut config = crate::config::ServiceConfig {
            tui_socket_dir: std::path::PathBuf::from("/tmp"),
            default_session: "main".into(),
            default_socket: None,
            file_roots: Vec::new(),
            acpmux: crate::config::AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: std::path::PathBuf::from("/tmp"),
            upload_max_bytes: 1,
            chief_socket: None,
            browser: crate::browser::BrowserConfig::default(),
            surface: Default::default(),
        };
        assert_eq!(capabilities(&config), ["removal-v1"]);
        let launcher: crate::browser::Launcher = std::sync::Arc::new(|_| {
            Box::pin(async { Err::<crate::browser::RunningHost, _>("none".to_owned()) })
        });
        config.browser = crate::browser::BrowserConfig::new(Some(launcher), 1);
        assert_eq!(capabilities(&config), ["removal-v1", BROWSER_STREAM, BROWSER_VIDEO_TRACK]);
    }

    #[test]
    fn upload_names_are_safe() {
        assert_eq!(safe_file_name("photo.jpg"), "photo.jpg");
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name("a\\b.txt"), "b.txt");
        assert_eq!(safe_file_name(".bashrc"), "bashrc");
        assert_eq!(safe_file_name("..."), "attachment");
        assert_eq!(safe_file_name("a\nb:c"), "a_b_c");
        assert_eq!(safe_file_name(""), "attachment");
        assert!(safe_file_name(&"é".repeat(200)).len() <= 120);
    }

    #[test]
    fn publish_never_replaces() {
        let folder = tempfile::tempdir().unwrap();
        std::fs::write(folder.path().join("a.txt"), "old").unwrap();
        let part = folder.path().join(".x.part");
        std::fs::write(&part, "new").unwrap();
        let path = publish_upload(folder.path(), "a.txt", &part).unwrap();
        assert_eq!(path, folder.path().join("a 2.txt"));
        assert_eq!(std::fs::read_to_string(folder.path().join("a.txt")).unwrap(), "old");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "new");
        assert!(!part.exists());
    }

    #[test]
    fn acpmux_messages_are_joined() {
        let mut assembler = MessageAssembler::default();
        assert_eq!(assembler.push(br#"{"jsonrpc":"2.0","params":{"a":"#).unwrap(), None);
        assert_eq!(
            assembler.push(br#""xy"}}"#).unwrap().as_deref(),
            Some(r#"{"jsonrpc":"2.0","params":{"a":"xy"}}"#)
        );
        assert_eq!(assembler.push(br#"{"b":1}"#).unwrap().as_deref(), Some(r#"{"b":1}"#));
        assert_eq!(assembler.push(b"not json").unwrap_err().code, "bad_request");
    }

    #[test]
    fn session_names() {
        assert!(valid_session_name("main"));
        assert!(valid_session_name("dev-1.x"));
        assert!(!valid_session_name("../x"));
        assert!(!valid_session_name(".hidden"));
        assert!(!valid_session_name(""));
    }

    #[tokio::test]
    async fn a_fifo_inside_a_root_is_refused_without_blocking() {
        let root = tempfile::tempdir().unwrap();
        let fifo = root.path().join("pipe");
        let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path and mode.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let resolved = confine(&[root.path().to_path_buf()], &fifo).unwrap();
        let mut options = tokio::fs::OpenOptions::new();
        options.read(true).custom_flags(libc::O_NONBLOCK);
        let open = options.open(&resolved);
        let file = tokio::time::timeout(std::time::Duration::from_secs(2), open)
            .await
            .expect("open blocked")
            .unwrap();
        assert!(!file.metadata().await.unwrap().is_file());
    }

    #[test]
    fn workspace_folders_share_projects_never_home_or_above() {
        // Full verify D9: the phone's chat edits files in its workspace folder,
        // which the Mac shares with phones (agentcwd); home and its ancestors never.
        let home = Path::new("/Users/me");
        let folders = vec![
            PathBuf::from("/Users/me/code/app"),
            PathBuf::from("/Users/me"),
            PathBuf::from("/Users"),
            PathBuf::from("/"),
            PathBuf::from("/tmp/scratch"),
            PathBuf::from("/Users/me/code/app"),
            // A cwd any output can set (OSC 7) inside credential trees: never shared.
            PathBuf::from("/Users/me/.ssh"),
            PathBuf::from("/Users/me/Library/Keychains"),
            PathBuf::from("/Users/me/.config/gh"),
        ];
        assert_eq!(
            shareable_workspace_folders(folders, home),
            vec![PathBuf::from("/Users/me/code/app"), PathBuf::from("/tmp/scratch")]
        );
    }

    #[test]
    fn a_file_in_a_workspace_folder_is_inside_the_shared_roots() {
        let project = tempfile::tempdir().unwrap();
        std::fs::write(project.path().join("README.md"), "r").unwrap();
        let home = tempfile::tempdir().unwrap();
        let roots = shared_file_roots(
            &[],
            vec![project.path().to_path_buf(), home.path().to_path_buf()],
            home.path(),
        );
        assert!(confine(&roots, &project.path().join("README.md")).is_ok());
        assert_eq!(roots.len(), 1, "home is never a root: {roots:?}");
        // A home that doesn't resolve shares no workspace folder at all.
        let gone = home.path().join("missing");
        assert!(shared_file_roots(&[], vec![project.path().to_path_buf()], &gone).is_empty());
    }

    #[test]
    fn confine_keeps_reads_inside_roots() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "a").unwrap();
        std::fs::write(outside.path().join("secret"), "s").unwrap();
        std::os::unix::fs::symlink(outside.path().join("secret"), root.path().join("link")).unwrap();
        let roots = vec![root.path().to_path_buf()];
        assert!(confine(&roots, &root.path().join("a.txt")).is_ok());
        assert_eq!(confine(&roots, &root.path().join("link")).unwrap_err().code, "forbidden");
        assert_eq!(confine(&roots, &root.path().join("../x")).unwrap_err().code, "not_found");
        assert_eq!(confine(&roots, Path::new("a.txt")).unwrap_err().code, "bad_request");
        assert_eq!(confine(&[], &root.path().join("a.txt")).unwrap_err().code, "forbidden");
    }
}

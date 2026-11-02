//! Link services (PROTOCOL.md "Services"). Default deny: a service not
//! listed here is closed with `unknown_service`.

use std::collections::HashMap;
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
use tokio::time::{Duration, timeout};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::chief_policy::ChiefPolicy;
use crate::cloud_acp::{Adapter as CloudAcpAdapter, Effects as CloudAcpEffects};
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
        "cloud-directory" => cloud_directory(&sender, &args).await,
        "cloud-acpmux" => cloud_acpmux(&sender, receiver, &args).await,
        "file" => file(&config, &args, &sender, false).await,
        "file-preview" => file(&config, &args, &sender, true).await,
        "upload" => upload(&config, &peer, &args, &sender, receiver).await,
        "version" => version(&config, &sender).await,
        "browser" => crate::browser::serve(&config.browser, &*config, &peer, &args, &sender, receiver).await,
        "surface" => crate::surface::serve(&config.surface, &*config, &peer, &args, &sender, receiver).await,
        "localhost" => crate::localhost::serve(&args, &sender, receiver).await,
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
/// `localhost-forward-v1`: the `localhost` service (a phone's native browser tab
/// reaches a port on this Mac's loopback).
pub const CAPABILITIES: [&str; 5] =
    ["removal-v1", "file-preview-v1", "localhost-forward-v1", "cloud-directory-v1", "cloud-acpmux-v1"];
/// Added to [`CAPABILITIES`] when this Mac can stream browser tabs (`browser`).
pub const BROWSER_STREAM: &str = "browser-stream-v1";
/// With [`BROWSER_STREAM`]: `browser {"video": "track"}` carries the page's
/// video on the link's media lane when the link has one.
pub const BROWSER_VIDEO_TRACK: &str = "browser-video-track-v1";
/// Added when this Mac streams its phone tabs' simulators (`surface`), with
/// `video: "track"` as for browser tabs.
pub const SURFACE_STREAM: &str = "surface-stream-v1";
/// Added with [`SURFACE_STREAM`]: `surface` also streams the owner's own Cloud
/// machine desktop, view only (`c~<machine_id>~<team_id>`, `surface.rs`).
pub const CLOUD_DESKTOP: &str = "cloud-desktop-v1";

/// What this host does that a phone may rely on.
pub fn capabilities(config: &ServiceConfig) -> Vec<&'static str> {
    let mut out = CAPABILITIES.to_vec();
    if config.browser.available() {
        out.push(BROWSER_STREAM);
        out.push(BROWSER_VIDEO_TRACK);
    }
    if config.surface.streams_simulators() {
        out.push(SURFACE_STREAM);
    }
    if config.surface.available() {
        out.push(CLOUD_DESKTOP);
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

/// Whether `value` is a Cloud machine or team id as the phone may name one
/// (never `~`, the `surface` Cloud desktop key's separator).
pub(crate) fn valid_cloud_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

fn cloud_id(value: Option<&Value>, name: &str) -> Result<String, Refusal> {
    let Some(value) = value.and_then(Value::as_str) else {
        return Err(Refusal::new("bad_request", format!("{name} is required")));
    };
    let value = value.trim();
    if !valid_cloud_id(value) {
        return Err(Refusal::new("bad_request", format!("invalid {name}")));
    }
    Ok(value.to_owned())
}

/// The one link the app lists for `machine_id` in `team_id`, when this account
/// owns it; `forbidden` for none, several, or a machine it does not own.
pub(crate) fn owned_cloud_link(
    links: Vec<control::CloudLink>,
    machine_id: &str,
    team_id: &str,
) -> Result<control::CloudLink, Refusal> {
    let mut matches = links
        .into_iter()
        .filter(|link| link.machine_id == machine_id && link.team_id == team_id)
        .collect::<Vec<_>>();
    match matches.pop() {
        Some(link) if matches.is_empty() && link.owner => Ok(link),
        _ => Err(Refusal::new("forbidden", "Cloud machine is not an unambiguous authenticated owner link")),
    }
}

/// A machine state as the phone sees it: the app's status word, or `unknown`.
fn cloud_status(status: &str) -> &str {
    if !status.is_empty() && status.len() <= 32 && status.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
    {
        status
    } else {
        "unknown"
    }
}

/// The `cloud-directory` reply: whether the account pays for Cloud, and its
/// owned machines that are listed once. Carrier paths and owner markers are
/// never exposed to the phone.
pub(crate) fn cloud_directory_reply(snapshot: control::CloudLinks) -> Value {
    let mut counts = HashMap::<(String, String), usize>::new();
    for link in &snapshot.links {
        *counts.entry((link.machine_id.clone(), link.team_id.clone())).or_default() += 1;
    }
    let machines = snapshot
        .links
        .into_iter()
        .filter(|link| link.owner && counts.get(&(link.machine_id.clone(), link.team_id.clone())) == Some(&1))
        .map(|link| {
            serde_json::json!({
                "machine_id": link.machine_id,
                "team_id": link.team_id,
                "name": link.name,
                "status": cloud_status(&link.status),
                "ran": link.ran,
            })
        })
        .collect::<Vec<_>>();
    serde_json::json!({"paid": snapshot.paid, "desktops": snapshot.desktops, "machines": machines})
}

/// Return only authenticated Cloud machines ([`cloud_directory_reply`]).
async fn cloud_directory(sender: &ChannelSender, args: &Value) -> Result<(), Refusal> {
    if !args.is_object() || args.as_object().is_some_and(|object| !object.is_empty()) {
        return Err(Refusal::new("bad_request", "cloud-directory takes no arguments"));
    }
    let snapshot =
        control::request_cloud_links().await.map_err(|message| Refusal::new("unavailable", message))?;
    sender
        .send(Bytes::from(cloud_directory_reply(snapshot).to_string()))
        .await
        .map_err(|_| Refusal::new("closed", "phone channel closed"))
}

/// Open an authenticated Cloud carrier. The phone supplies ids only; the app
/// resolves the current owner link and socket, then the carrier's scoped ACP
/// adapter applies Web/phone mode and approval policy.
async fn cloud_acpmux(
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
    args: &Value,
) -> Result<(), Refusal> {
    let object = args
        .as_object()
        .ok_or_else(|| Refusal::new("bad_request", "cloud-acpmux arguments must be an object"))?;
    if object.keys().any(|key| key != "machine_id" && key != "team_id") {
        return Err(Refusal::new("bad_request", "cloud-acpmux accepts only machine_id and team_id"));
    }
    let machine_id = cloud_id(object.get("machine_id"), "machine_id")?;
    let team_id = cloud_id(object.get("team_id"), "team_id")?;
    let snapshot =
        control::request_cloud_links().await.map_err(|message| Refusal::new("unavailable", message))?;
    let link = owned_cloud_link(snapshot.links, &machine_id, &team_id)?;
    let path =
        link.socket.ok_or_else(|| Refusal::new("unavailable", "Cloud machine link has no carrier socket"))?;
    if !path.is_absolute() {
        return Err(Refusal::new("unavailable", "Cloud machine link has an invalid carrier socket"));
    }
    let socket = UnixStream::connect(&path)
        .await
        .map_err(|error| Refusal::new("unavailable", format!("Cloud carrier unavailable: {error}")))?;
    let (read, mut write) = socket.into_split();
    let mut read = BufReader::new(read);
    timeout(Duration::from_secs(5), cloud_mobile_handshake(&mut read, &mut write))
        .await
        .map_err(|_| Refusal::new("timeout", "Cloud carrier handshake timed out"))??;
    let mut native_line = Vec::new();
    let mut phone_message = MessageAssembler::default();
    let mut adapter = CloudAcpAdapter::new(machine_id.clone(), team_id.clone());
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            event = receiver.recv() => match event {
                Some(ChannelEvent::Data(bytes)) => {
                    let Some(message) = phone_message.push(&bytes)? else { continue; };
                    let request: Value = serde_json::from_str(message.as_str())
                        .map_err(|_| Refusal::new("bad_request", "Cloud ACP frame is not JSON"))?;
                    let effects = adapter.phone(request).map_err(|_| Refusal::new("bad_request", "Cloud ACP request refused"))?;
                    if apply_cloud_effects(&mut write, sender, effects).await.is_err() { break; }
                }
                Some(ChannelEvent::Closed(_)) | None => break,
            },
            native = read_cloud_line(&mut read, &mut native_line) => {
                let line = native?;
                let response: Value = serde_json::from_slice(&line)
                    .map_err(|_| Refusal::new("unavailable", "Cloud carrier returned invalid JSON"))?;
                let effects = adapter.native(response).map_err(|_| Refusal::new("unavailable", "Cloud native reply refused"))?;
                if apply_cloud_effects(&mut write, sender, effects).await.is_err() { break; }
            }
            _ = tick.tick() => {
                let effects = adapter.expire();
                if apply_cloud_effects(&mut write, sender, effects).await.is_err() { break; }
            }
        }
    }
    Ok(())
}

const MAX_CLOUD_NATIVE_LINE: usize = 8 * 1024 * 1024;

// The app already dialed the authenticated native carrier. Identify the VM's
// supported policy before marking this connection mobile; an old daemon may
// accept unknown client capabilities without enforcing them.
async fn cloud_mobile_handshake<R, W>(read: &mut R, write: &mut W) -> Result<(), Refusal>
where
    R: tokio::io::AsyncBufRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    for request in [
        serde_json::json!({"cmd":"identify","id":"cloud-mobile-identify"}),
        serde_json::json!({"cmd":"set-client-info","id":"cloud-mobile-host",
            "kind":"ios","device_kind":"iphone",
            "capabilities":["cloud-mobile-chat-v1","conversation-tabs-v1","agent-session-tabs-v1"]}),
    ] {
        write
            .write_all(request.to_string().as_bytes())
            .await
            .map_err(|_| Refusal::new("unavailable", "Cloud carrier closed"))?;
        write.write_all(b"\n").await.map_err(|_| Refusal::new("unavailable", "Cloud carrier closed"))?;
        let bytes = read_cloud_line(read, &mut Vec::new()).await?;
        let response: Value = serde_json::from_slice(&bytes)
            .map_err(|_| Refusal::new("unavailable", "Cloud carrier returned an invalid handshake"))?;
        if response.get("id") != request.get("id")
            || response.get("ok").and_then(Value::as_bool) != Some(true)
        {
            return Err(Refusal::new("forbidden", "Cloud carrier refused mobile chat handshake"));
        }
        if request["cmd"] == "identify"
            && !response
                .pointer("/data/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|caps| caps.iter().any(|cap| cap == "cloud-mobile-chat-v1"))
        {
            return Err(Refusal::new(
                "forbidden",
                "Cloud machine does not support phone prompt restrictions",
            ));
        }
    }
    Ok(())
}

async fn read_cloud_line<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
    line: &mut Vec<u8>,
) -> Result<Vec<u8>, Refusal> {
    loop {
        let chunk =
            reader.fill_buf().await.map_err(|_| Refusal::new("unavailable", "Cloud carrier closed"))?;
        if chunk.is_empty() {
            return Err(Refusal::new("unavailable", "Cloud carrier closed"));
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let take = newline.unwrap_or(chunk.len());
        if line.len().saturating_add(take) > MAX_CLOUD_NATIVE_LINE {
            return Err(Refusal::new("bad_request", "Cloud carrier line is too large"));
        }
        line.extend_from_slice(&chunk[..take]);
        reader.consume(take + usize::from(newline.is_some()));
        if newline.is_some() {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(std::mem::take(line));
        }
        // Keep the accumulated bytes outside the future. If select! cancels this
        // read while a phone frame arrives, the next poll resumes from this exact
        // partial line instead of dropping it.
    }
}

async fn apply_cloud_effects(
    write: &mut tokio::net::unix::OwnedWriteHalf,
    sender: &ChannelSender,
    effects: CloudAcpEffects,
) -> Result<(), ()> {
    for value in effects.to_native {
        let bytes = serde_json::to_vec(&value).map_err(|_| ())?;
        write.write_all(&bytes).await.map_err(|_| ())?;
        write.write_all(b"\n").await.map_err(|_| ())?;
    }
    for value in effects.to_phone {
        let bytes = serde_json::to_vec(&value).map_err(|_| ())?;
        sender.send(Bytes::from(bytes)).await.map_err(|_| ())?;
    }
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

/// Bound an unanswered ordered command; its splice closes on expiry. Terminal
/// sends, long-running `wait-for` reads and close handling never wait on this timer.
const SIDE_COMPLETION_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

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

    let side_completion = Arc::new(crate::side_completion::SideCompletion::default());
    // Clear pending mutation authority before the service closes, even if its
    // child tasks have only been scheduled for cancellation.
    let _completion_scope = side_completion.scope();
    let completed = Arc::clone(&side_completion);

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
                    let line = completed.answer(line);
                    let Some(line) = reply_policy.reply(line) else { continue };
                    if daemon_lines.send(line).await.is_err() {
                        return;
                    }
                }
            }
        }
    });

    // Cold/invalidated side queries wait only in this bounded worker. `send`
    // continues on the input task while the cache refreshes on its own socket.
    let cache = terminal_folders.clone().map(crate::workspace_cache::WorkspaceCache::start);
    let (side_tx, mut side_rx) = mpsc::channel::<(Vec<u8>, Verdict)>(256);
    let (ready_tx, mut side_ready) = mpsc::channel::<Verdict>(256);
    let side_cache = cache.clone();
    // JoinSet also aborts this worker if the service future is cancelled.
    let mut side_workers = tokio::task::JoinSet::new();
    side_workers.spawn(async move {
        while let Some((line, verdict)) = side_rx.recv().await {
            let Some(cache) = &side_cache else { return };
            if let Some((tree, personal, layout)) = side_requirements(&line) {
                cache.wait_for(tree, personal, layout).await;
            }
            let verdict = owned_check(cache, &line, verdict);
            match verdict {
                Verdict::Refuse(answer) => {
                    if ready_tx.send(Verdict::Refuse(answer)).await.is_err() {
                        return;
                    }
                }
                _ => {
                    // A terminal-output wait is a read, not a mutation barrier.
                    // Forward it in order after earlier mutations, then let the
                    // daemon own its requested timeout while later commands run.
                    // Its response keeps the original ID and needs no cache invalidation.
                    if is_terminal_wait(&line) {
                        if ready_tx.send(Verdict::Rewrite(line)).await.is_err() {
                            return;
                        }
                        continue;
                    }
                    let changes_state = changes_cached_state(&line);
                    let line = with_pane_folder(cache.tree().as_deref(), line);
                    let Some((line, completion)) =
                        side_completion.prepare(line, changes_state.then(|| cache.clone()))
                    else {
                        return;
                    };
                    if ready_tx.send(Verdict::Rewrite(line)).await.is_err() {
                        return;
                    }
                    // Only this worker waits. Terminal sends, daemon replies,
                    // close handling and size release remain live on their tasks.
                    if !matches!(tokio::time::timeout(SIDE_COMPLETION_WAIT, completion).await, Ok(Ok(()))) {
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
                ready = side_ready.recv(), if claims => {
                    let Some(ready) = ready else { return };
                    match ready {
                        Verdict::Rewrite(mut line) => {
                            sized.observe(&line);
                            line.push(b'\n');
                            if daemon_write.write_all(&line).await.is_err() { return; }
                        }
                        Verdict::Refuse(answer) => {
                            let mut answer = answer.into_bytes();
                            answer.push(b'\n');
                            if refusals.send(answer).await.is_err() { return; }
                        }
                        Verdict::Forward => unreachable!("side worker returns the checked line"),
                    }
                    continue;
                }
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
                // A reply to a terminal notification is answered locally. Keep it
                // in the input task so it cannot be confused with an ordinary rewrite.
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
                // Preserve ordering for commands/mutations. Only explicit terminal
                // input bypasses a side query waiting for its cached snapshots.
                let checked = match &verdict {
                    Verdict::Forward => Some(&line),
                    Verdict::Rewrite(checked) => Some(checked),
                    Verdict::Refuse(_) => None,
                };
                if claims
                    && checked.is_some_and(|line| !is_terminal_input(line) && !is_notification_reply(line))
                {
                    let request = checked.unwrap().clone();
                    if side_tx.try_send((request, verdict)).is_err() {
                        let mut answer = side_busy(&line).into_bytes();
                        answer.push(b'\n');
                        if refusals.send(answer).await.is_err() {
                            return;
                        }
                    }
                    continue;
                }
                match verdict {
                    Verdict::Forward => {
                        if claims {
                            sized.observe(&line);
                        }
                        line.push(b'\n');
                        if daemon_write.write_all(&line).await.is_err() {
                            return;
                        }
                    }
                    Verdict::Rewrite(mut line) => {
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
    side_workers.abort_all();
    to_daemon.abort();
    from_daemon.abort();
    Ok(())
}

fn is_terminal_wait(line: &[u8]) -> bool {
    serde_json::from_slice::<Value>(line)
        .ok()
        .is_some_and(|request| request.get("cmd").and_then(Value::as_str) == Some("wait-for"))
}

/// Reads do not dirty the cached state. Unknown operations conservatively do.
fn changes_cached_state(line: &[u8]) -> bool {
    let Ok(request) = serde_json::from_slice::<Value>(line) else { return true };
    !request.get("cmd").and_then(Value::as_str).is_some_and(|cmd| {
        cmd.starts_with("list-") || matches!(cmd, "identify" | "set-client-info" | "subscribe")
    })
}

fn side_busy(line: &[u8]) -> String {
    let request = serde_json::from_slice::<Value>(line).unwrap_or(Value::Null);
    let id = request.get("id");
    if request.get("protocol").and_then(Value::as_str) == Some("cmux.protocol/2") {
        serde_json::json!({"id":id, "protocol":"cmux.protocol/2", "type":"response", "ok":false,
            "error":{"code":"busy", "message":"too many pending side requests", "retryable":true}})
        .to_string()
    } else {
        crate::policy::error_line(id, "busy", "too many pending side requests")
    }
}

/// Text, named keys, and clear-history (which can write a fallback key) share
/// the input path, preserving wire order while bypassing workspace queries.
fn is_terminal_input(line: &[u8]) -> bool {
    serde_json::from_slice::<Value>(line).ok().is_some_and(|v| {
        matches!(v.get("cmd").and_then(Value::as_str), Some("send" | "send-key" | "clear-history"))
            && (v.get("surface").and_then(Value::as_u64).is_some()
                || v.get("terminal_id").and_then(Value::as_str).is_some())
    })
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

/// `file`: stream one regular file of any size inside a workspace root, then
/// close with `eof`. The roots are the Chat Folders, then (only when the file is
/// outside them) the Mac's workspace folders as they are now. `file-preview`
/// prepends metadata from the same open descriptor before streaming those bytes.
async fn file(
    config: &ServiceConfig,
    args: &Value,
    sender: &ChannelSender,
    preview_metadata: bool,
) -> Result<(), Refusal> {
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
    let file = tokio::fs::OpenOptions::new()
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
    // A distinct service keeps old hosts' raw file bytes from being mistaken for
    // metadata. Read the size from this descriptor, after all confinement checks,
    // so the phone can check free storage before accepting the file's contents.
    if preview_metadata
        && sender.send(Bytes::from(serde_json::json!({"size": metadata.len()}).to_string())).await.is_err()
    {
        return Ok(());
    }
    // Any size streams (Leo: "arbitrarily large files of any type"): one buffer at a time,
    // each send waiting for room in the channel's bounded queue, so memory stays bounded
    // whatever the file's size. The read stops at the size the file had when it was
    // opened, so a file that keeps growing (a log) still ends.
    let mut file = file.take(metadata.len());
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

/// Which cached views a side request needs. Ordinary keystrokes bypass this
/// worker; a cold workspace/group lookup cannot hold terminal input.
fn side_requirements(line: &[u8]) -> Option<(bool, bool, bool)> {
    use crate::policy::Ownership;
    match crate::policy::ownership(line) {
        Some(Ownership::PersonalWorkspace { .. }) => Some((true, false, false)),
        Some(Ownership::PinnedWorkspaceTile { .. }) => Some((false, false, true)),
        Some(Ownership::OwnGroup { .. }) => Some((true, true, false)),
        Some(Ownership::PlaceWorkspace { group, .. }) => Some((true, group.is_some(), false)),
        None => serde_json::from_slice::<Value>(line)
            .ok()
            .filter(|v| {
                v.get("cmd").and_then(Value::as_str) == Some("new-tab")
                    && v.get("pane").and_then(Value::as_u64).is_some()
            })
            .map(|_| (true, false, false)),
    }
}

/// Confirm ownership against the live cache; a missing/invalid snapshot never
/// grants access. Snapshot refresh runs separately from keystroke forwarding.
fn owned_check(cache: &crate::workspace_cache::WorkspaceCache, line: &[u8], verdict: Verdict) -> Verdict {
    use crate::policy::{
        Ownership, is_pinned_workspace_tile, lists_workspace, not_owned, ownership, owns_group,
        owns_personal_workspace, registry_id,
    };
    let Some(what) = ownership(line) else { return verdict };
    let tree = cache.tree();
    let owned = match &what {
        Ownership::PersonalWorkspace { session, key } => {
            tree.as_ref().is_some_and(|reply| owns_personal_workspace(reply, session, key))
        }
        Ownership::PinnedWorkspaceTile { item } => {
            cache.layout().as_ref().is_some_and(|reply| is_pinned_workspace_tile(reply, item))
        }
        Ownership::OwnGroup { group } => tree.as_ref().is_some_and(|tree| {
            registry_id(tree).is_some_and(|registry| {
                cache.personal().as_ref().is_some_and(|personal| owns_group(personal, registry, group))
            })
        }),
        Ownership::PlaceWorkspace { workspace, group } => tree.as_ref().is_some_and(|tree| {
            lists_workspace(tree, workspace)
                && match (group, registry_id(tree)) {
                    (None, _) => true,
                    (Some(group), Some(registry)) => cache
                        .personal()
                        .as_ref()
                        .is_some_and(|personal| owns_group(personal, registry, group)),
                    (Some(_), None) => false,
                }
        }),
    };
    if owned { verdict } else { Verdict::Refuse(not_owned(line, &what)) }
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
fn with_pane_folder(reply: Option<&Value>, line: Vec<u8>) -> Vec<u8> {
    let Ok(Value::Object(mut object)) = serde_json::from_slice::<Value>(&line) else { return line };
    if object.get("cmd").and_then(Value::as_str) != Some("new-tab") || object.contains_key("cwd") {
        return line;
    }
    let Some(pane) = object.get("pane").and_then(Value::as_u64) else { return line };
    let Some(reply) = reply else { return line };
    let home = std::env::var_os("HOME").and_then(|h| std::fs::canonicalize(h).ok());
    let Some(folder) = pane_folder(reply, pane, home.as_deref()) else { return line };
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
/// executed, and a short or long upload leaves no file. Any `size` is
/// accepted: the bytes stream to disk as they arrive (attachments have no
/// size cap). `size` may be a JSON number or a decimal string (the app's
/// channel arguments are strings).
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

    /// The forwarding loop uses the cached tree and does no socket I/O.
    #[test]
    fn a_phones_new_tab_line_gets_the_macs_folder() {
        let base = tempfile::tempdir().unwrap();
        let project = std::fs::canonicalize(base.path()).unwrap().join("project");
        std::fs::create_dir_all(&project).unwrap();
        let reply = serde_json::json!({"data": {"workspaces": [{"screens": [{"panes": [
            {"id": 3, "active_tab": 0, "tabs": [{"cwd": project}]}]}]}]}});
        let line = with_pane_folder(
            Some(&reply),
            br#"{"id":1,"cmd":"new-tab","pane":3,"cols":80,"rows":24}"#.to_vec(),
        );
        let sent: Value = serde_json::from_slice(&line).unwrap();
        assert_eq!(sent["cwd"].as_str(), project.to_str());
        let own = br#"{"id":2,"cmd":"new-tab","pane":3,"cwd":"/x"}"#.to_vec();
        assert_eq!(with_pane_folder(Some(&reply), own.clone()), own);
        let other = br#"{"id":3,"cmd":"select-tab","surface":1}"#.to_vec();
        assert_eq!(with_pane_folder(Some(&reply), other.clone()), other);
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
            chief_socket: None,
            browser: crate::browser::BrowserConfig::default(),
            surface: Default::default(),
        };
        assert_eq!(
            capabilities(&config),
            [
                "removal-v1",
                "file-preview-v1",
                "localhost-forward-v1",
                "cloud-directory-v1",
                "cloud-acpmux-v1"
            ]
        );
        let launcher: crate::browser::Launcher = std::sync::Arc::new(|_| {
            Box::pin(async { Err::<crate::browser::RunningHost, _>("none".to_owned()) })
        });
        config.browser = crate::browser::BrowserConfig::new(Some(launcher), 1);
        assert_eq!(
            capabilities(&config),
            [
                "removal-v1",
                "file-preview-v1",
                "localhost-forward-v1",
                "cloud-directory-v1",
                "cloud-acpmux-v1",
                BROWSER_STREAM,
                BROWSER_VIDEO_TRACK
            ]
        );
    }

    fn cloud_link(machine: &str, team: &str, owner: bool, status: &str, ran: bool) -> control::CloudLink {
        control::CloudLink {
            machine_id: machine.into(),
            team_id: team.into(),
            name: format!("{machine} box"),
            socket: Some("/tmp/cloud.sock".into()),
            owner,
            status: status.into(),
            ran,
        }
    }

    #[test]
    fn cloud_directory_says_paid_status_and_ran_and_never_a_socket_or_owner() {
        let mut asleep = cloud_link("m2", "t", true, "paused", true);
        asleep.socket = None;
        let snapshot = control::CloudLinks {
            paid: true,
            desktops: true,
            links: vec![
                cloud_link("m1", "t", true, "running", true),
                asleep,
                // Not owned: never listed.
                cloud_link("m3", "t", false, "running", true),
                // Listed twice: ambiguous, never listed.
                cloud_link("m4", "t", true, "running", true),
                cloud_link("m4", "t", true, "paused", true),
                // A status word the phone cannot read becomes unknown.
                cloud_link("m5", "t", true, "Run ning/../", false),
            ],
        };
        let reply = cloud_directory_reply(snapshot);
        assert_eq!(
            reply,
            serde_json::json!({"paid": true, "desktops": true, "machines": [
                {"machine_id": "m1", "team_id": "t", "name": "m1 box", "status": "running", "ran": true},
                {"machine_id": "m2", "team_id": "t", "name": "m2 box", "status": "paused", "ran": true},
                {"machine_id": "m5", "team_id": "t", "name": "m5 box", "status": "unknown", "ran": false},
            ]})
        );
        let text = reply.to_string();
        assert!(!text.contains("socket") && !text.contains("cloud.sock") && !text.contains("owner"));
        // An older app's snapshot: not paid, nothing has run.
        assert_eq!(
            cloud_directory_reply(control::CloudLinks::default()),
            serde_json::json!({"paid": false, "desktops": false, "machines": []})
        );
    }

    #[test]
    fn only_one_owned_link_is_a_cloud_machine_the_phone_may_reach() {
        let owned = || cloud_link("m", "t", true, "running", true);
        assert_eq!(owned_cloud_link(vec![owned()], "m", "t").unwrap(), owned());
        for links in [
            vec![],
            vec![cloud_link("m", "t", false, "running", true)],
            vec![owned(), owned()],
            vec![cloud_link("m", "other", true, "running", true)],
        ] {
            assert_eq!(owned_cloud_link(links, "m", "t").unwrap_err().code, "forbidden");
        }
    }

    #[test]
    fn surface_streams_cloud_desktops_only_with_a_surface_source() {
        let launcher: crate::browser::Launcher = std::sync::Arc::new(|_| {
            Box::pin(async { Err::<crate::browser::RunningHost, _>("none".to_owned()) })
        });
        let mut config = crate::config::ServiceConfig {
            tui_socket_dir: std::path::PathBuf::from("/tmp"),
            default_session: "main".into(),
            default_socket: None,
            file_roots: Vec::new(),
            acpmux: crate::config::AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1".into(), token: None },
            pairing: None,
            agent_tab_host: None,
            uploads_dir: std::path::PathBuf::from("/tmp"),
            chief_socket: None,
            browser: crate::browser::BrowserConfig::default(),
            surface: Default::default(),
        };
        assert!(!capabilities(&config).contains(&CLOUD_DESKTOP));
        config.surface = crate::surface::SurfaceConfig::new(Some(launcher), 1);
        assert!(capabilities(&config).ends_with(&[SURFACE_STREAM, CLOUD_DESKTOP]));
        // A Mac whose app cannot stream simulators still streams Cloud desktops, and never says
        // `surface-stream-v1` (its phone would wait on a simulator that never opens).
        config.surface = config.surface.clone().without_simulators();
        assert!(!capabilities(&config).contains(&SURFACE_STREAM));
        assert!(capabilities(&config).ends_with(&[CLOUD_DESKTOP]));
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

    #[tokio::test]
    async fn cloud_handshake_refuses_old_daemons_before_sending_mobile_commands() {
        for (caps, allowed) in [
            (serde_json::json!([]), false),
            (serde_json::json!(["agent-session-tabs-v1"]), false),
            (serde_json::json!(["cloud-mobile-chat-v1"]), true),
        ] {
            let replies = format!(
                "{}\n{}\n",
                serde_json::json!({"id":"cloud-mobile-identify","ok":true,"data":{"capabilities":caps}}),
                serde_json::json!({"id":"cloud-mobile-host","ok":true})
            );
            let mut read = std::io::Cursor::new(replies.into_bytes());
            let mut write = Vec::new();
            let result = cloud_mobile_handshake(&mut read, &mut write).await;
            assert_eq!(result.is_ok(), allowed);
            let commands: Vec<Value> = String::from_utf8(write)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            assert_eq!(commands[0]["cmd"], "identify");
            assert_eq!(commands.len(), if allowed { 2 } else { 1 });
            if allowed {
                assert_eq!(commands[1]["capabilities"][0], "cloud-mobile-chat-v1");
            }
        }
    }

    #[tokio::test]
    async fn cloud_native_line_preserves_partial_data_when_read_is_cancelled() {
        let (mut writer, reader) = tokio::io::duplex(64);
        writer.write_all(b"{\"id\":1").await.unwrap();
        let mut reader = BufReader::new(reader);
        let mut partial = Vec::new();
        assert!(
            tokio::time::timeout(Duration::from_millis(5), read_cloud_line(&mut reader, &mut partial),)
                .await
                .is_err()
        );
        assert_eq!(partial, br#"{"id":1"#);
        writer.write_all(b"}\n").await.unwrap();
        assert_eq!(read_cloud_line(&mut reader, &mut partial).await.unwrap(), br#"{"id":1}"#);
    }

    #[tokio::test]
    async fn cloud_native_line_rejects_oversize_before_newline() {
        let (mut writer, reader) = tokio::io::duplex(MAX_CLOUD_NATIVE_LINE + 16);
        writer.write_all(&vec![b'x'; MAX_CLOUD_NATIVE_LINE + 1]).await.unwrap();
        let mut reader = BufReader::new(reader);
        let mut partial = Vec::new();
        assert_eq!(read_cloud_line(&mut reader, &mut partial).await.unwrap_err().code, "bad_request");
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

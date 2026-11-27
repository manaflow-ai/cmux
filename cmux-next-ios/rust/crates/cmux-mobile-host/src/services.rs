//! Link services (PROTOCOL.md "Services"). Default deny: a service not
//! listed here is closed with `unknown_service`.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use bytes::Bytes;
use cmux_mobile_link::link::{ChannelReceiver, ChannelSender};
use cmux_mobile_link::names::HostService;
use cmux_mobile_link::{ChannelEvent, IncomingChannel, names};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufReader, SeekFrom};
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
    /// The link session (a UUID). Legacy uploads use one folder per session.
    pub session_id: String,
    /// The link's media lane (browser video as RTP: a WebRTC track or UDP
    /// inside the WireGuard tunnel), if the
    /// phone and this Mac negotiated one.
    pub video: Option<cmux_mobile_link::media::VideoOut>,
    pub session_exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
    /// The link's path and a direct path's peer address, for its route
    /// ([`cmux_mobile_link::dial::route_name`]); `None` off a dialed link.
    pub route: Option<LinkRoute>,
    /// The link's path now (direct, TURN, TURN over TLS), if the link reports one.
    pub path: Option<tokio::sync::watch::Receiver<cmux_mobile_link::dial::LinkPath>>,
    /// The link's viewport sync port, on a WireGuard overlay (`None` elsewhere).
    pub viewport: Option<Arc<crate::viewport_link::LinkHub>>,
}

/// What the link's route is read from.
#[derive(Debug, Clone)]
pub struct LinkRoute {
    pub path: tokio::sync::watch::Receiver<cmux_mobile_link::dial::LinkPath>,
    pub peer: cmux_mobile_link::dial::PeerAddr,
}

impl LinkRoute {
    /// The route now: `direct-lan`, `direct-wan`, `direct`, `relay` or `none`.
    pub fn name(&self) -> &'static str {
        cmux_mobile_link::dial::route_name(*self.path.borrow(), *self.peer.borrow())
    }
}

impl Peer {
    /// The wire name of the link's path now (`direct`, `turn`, `turn-tls`, `none`).
    pub fn path_name(&self) -> Option<&'static str> {
        self.path.as_ref().map(|path| crate::control::path_name(*path.borrow()))
    }
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
    serve_with_upload_timeout(config, peer, link, incoming, UPLOAD_STALL_TIMEOUT).await;
}

/// Serve a channel with a host-selected inactivity deadline for resumable uploads.
pub async fn serve_with_upload_timeout(
    config: Arc<ServiceConfig>,
    peer: Peer,
    link: Arc<crate::pairing::LinkAuth>,
    incoming: IncomingChannel,
    upload_timeout: Duration,
) {
    let IncomingChannel { service, args, lane, channel } = incoming;
    let (mut sender, mut receiver) = channel.split();
    // Every payload byte of the channel counts toward its kind (traffic.rs).
    let meter = crate::traffic::TRAFFIC.meter(crate::traffic::Kind::of_service(&service, &args));
    sender.count_into(Arc::clone(&meter));
    receiver.count_into(meter);
    tracing::info!(
        service,
        channel = sender.id(),
        ?lane,
        own_stream = sender.on_input_stream(),
        peer = peer.device_id,
        "channel opened"
    );
    let host_service = HostService::parse(&service);
    let gate = if config.pairing.is_none() || host_service == Some(HostService::Auth) {
        crate::pairing::Gate::Paired
    } else {
        link.gate().await
    };
    // A machine (not a phone) opens only what the person granted it on this Mac,
    // read again at every open so a removed or narrowed peer loses it at once.
    let machine_grants = if host_service == Some(HostService::Auth) || gate != crate::pairing::Gate::Paired {
        None
    } else {
        machine_grants(&config, &peer, &link)
    };
    if let Some(grants) = &machine_grants {
        let decision = match grants {
            Ok(grants) => crate::peer::allows(grants, &service),
            Err(code) => Err(*code),
        };
        if let Some(pairing) = config.pairing.as_ref() {
            let kind = link.peer().map(|(kind, _)| kind.as_str()).unwrap_or("mac");
            pairing.activity.record(crate::activity::Entry {
                at_ms: crate::activity::now_ms(),
                peer: peer.device_id.clone(),
                kind,
                direction: "in",
                service: service.clone(),
                decision: decision.err().unwrap_or("allowed").to_owned(),
                target: None,
            });
        }
        if let Err(code) = decision {
            let reason = match code {
                "revoked" => "this Mac no longer allows that machine".to_owned(),
                "not_offered" => format!("{service} is not offered to machines"),
                _ => format!("this Mac has not allowed that machine to use {service}"),
            };
            tracing::info!(service, code, peer = peer.device_id, "machine channel refused");
            sender.close(code, &reason).await;
            return;
        }
    }
    let result = match host_service {
        Some(HostService::Auth) => {
            crate::pairing::note_phone_app(&peer.device_id, &args, peer.path_name());
            crate::pairing::serve(
                config.pairing.as_ref(),
                &peer.device_id,
                &link,
                &args,
                &sender,
                &mut receiver,
            )
            .await
            .map_err(|(code, reason)| Refusal::new(code, reason))
        }
        _ if gate == crate::pairing::Gate::Busy => {
            Err(Refusal::new("busy", "too many channels wait for this iPhone's pairing"))
        }
        _ if gate != crate::pairing::Gate::Paired => {
            Err(Refusal::new("unpaired", "pair this iPhone with the Mac first (auth)"))
        }
        Some(HostService::Echo) => echo(&sender, receiver).await,
        Some(HostService::Daemon) => daemon(&config, &peer, &args, &sender, receiver).await,
        Some(HostService::Chief) => chief(&config, &peer, &sender, receiver).await,
        Some(HostService::Acpmux) => acpmux(&config, &peer, &args, &sender, receiver).await,
        Some(HostService::CloudDirectory) => cloud_directory(&sender, &args).await,
        Some(HostService::CatchUp) => crate::catch_up::serve(&config, &peer, &args, &sender).await,
        Some(HostService::CloudAcpmux) => cloud_acpmux(&sender, receiver, &args).await,
        Some(HostService::File) => file(&config, &args, &sender, false).await,
        Some(HostService::FilePreview) => file(&config, &args, &sender, true).await,
        Some(HostService::Upload) => upload(&config, &peer, &args, &sender, receiver, upload_timeout).await,
        Some(HostService::Bundle) => crate::bundle::serve(&config, &peer, &args, &sender, receiver).await,
        Some(HostService::Version) => version(&config, &sender).await,
        Some(HostService::Lan) => crate::lan::enroll(&peer, &args, &sender).await,
        Some(HostService::Machine) => {
            let grants = machine_grants.and_then(Result::ok).unwrap_or_default();
            let name = std::env::var("CMUX_MOBILE_DEVICE_NAME").unwrap_or_else(|_| crate::config::hostname());
            crate::machine::serve(&sender, &name, &grants).await
        }
        Some(HostService::NeedsYou) => crate::needs_you::serve(&sender, receiver).await,
        Some(HostService::PairRequests) => {
            crate::pair_requests::serve(config.pairing.as_ref(), &peer.device_id, &link, &args, &sender)
                .await
                .map_err(|(code, reason)| Refusal::new(code, reason))
        }
        Some(HostService::Appearance) => crate::appearance::serve(&sender, receiver, &peer.device_id).await,
        // Swift live code patches for a cmux Dev app on this phone (live_code.rs).
        Some(HostService::LiveCode) => crate::live_code::serve(&sender, receiver).await,
        Some(HostService::AppearanceWallpaper) => crate::appearance::serve_wallpaper(&sender, &args).await,
        Some(HostService::Browser) => {
            crate::browser::serve(&config.browser, &*config, &peer, &args, &sender, receiver).await
        }
        Some(HostService::Surface) => {
            crate::surface::serve(&config.surface, &*config, &peer, &args, &sender, receiver).await
        }
        Some(HostService::Localhost) => crate::localhost::serve(&args, &sender, receiver).await,
        Some(HostService::TryPr) => crate::try_pr::serve(&sender, &args).await,
        Some(HostService::SiteData) => {
            let (socket, query) = (config.daemon_socket(), crate::site_data::tabs_query());
            let tabs = daemon_query(&socket, query.as_bytes(), "cmux-mobile-site-data");
            crate::site_data::serve(tabs, &args, &control::emit, &sender).await
        }
        Some(HostService::PhonePage) => {
            crate::phone_page::serve(&peer.device_id, &args, &sender, receiver).await
        }
        Some(HostService::PhoneFrames) => {
            let route = peer.route.clone();
            crate::phone_frames::serve_on(
                &peer.device_id,
                &crate::phone_frames::default_path(),
                &move || route.as_ref().map(LinkRoute::name),
                &sender,
                receiver,
            )
            .await
        }
        Some(HostService::Tabs) => {
            let tabs = &*crate::tab_snapshots::TABS;
            let socket = Some(config.daemon_socket());
            crate::tab_snapshots::serve(tabs, socket, peer.session_exposure.clone(), &sender, receiver).await
        }
        None => Err(Refusal::new("unknown_service", format!("no service {service}"))),
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

/// For a link whose `auth` was a machine's: the grants the app gives it now,
/// or `Err("revoked")` when the app no longer lists it. `None` for a phone, or
/// an unsupervised hostd.
fn machine_grants(
    config: &ServiceConfig,
    peer: &Peer,
    link: &crate::pairing::LinkAuth,
) -> Option<Result<Vec<crate::peer::Grant>, &'static str>> {
    let pairing = config.pairing.as_ref()?;
    let (kind, identity_key) = link.peer()?;
    if !kind.is_machine() {
        return None;
    }
    let trust = pairing.trust.borrow();
    Some(
        trust
            .as_ref()
            .and_then(|trust| trust.machine(&peer.device_id, &identity_key))
            .filter(|device| device.kind == kind)
            .map(|device| device.grants.clone())
            .ok_or("revoked"),
    )
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

/// The largest message the daemon's acpmux WebSocket sends or takes (acpmux `server/mod.rs`
/// `WS_MAX_MESSAGE_BYTES`).
const ACPMUX_MAX_MESSAGE_BYTES: usize = 64 << 20;

const UPLOAD_STALL_TIMEOUT: Duration = Duration::from_secs(120);
const UPLOAD_ACK_BYTES: u64 = 1 << 20;
const UPLOAD_PART_MAX_AGE: std::time::Duration = std::time::Duration::from_secs(24 * 60 * 60);

/// The `version` service's `capabilities` (PROTOCOL.md "Services").
/// `localhost-forward-v1`: the `localhost` service (a phone's native browser tab
/// reaches a port on this Mac's loopback).
/// `needs-you-v1`: the `needs-you` service (the Mac app's own open Feed requests, `needs_you.rs`).
/// `appearance-v1`: the `appearance` and `appearance-wallpaper` services (the Mac's theme and
/// wallpaper, `appearance.rs`).
/// `pair-requests-v1`: the `pair-requests` service (a paired device answers a pairing request
/// waiting on this Mac, `pair_requests.rs`).
/// `phone-frames-v1`: the `phone-frames` service (the phone's terminal scroll frame times,
/// logged to `phone-frames.jsonl`, `phone_frames.rs`).
/// `tab-snapshots-v1`: the `tabs` service (every tab's title, favicon, thumbnail or screen text,
/// with deltas and content-addressed blobs, `tab_snapshots.rs`).
/// `phone-page-v1`: the `phone-page` service (agents' `browser.page.*` calls on a tab the
/// phone shows itself, `phone_page.rs`).
/// `mailbox-send-v1`: the mailbox takes `send` and `compose` items, held up to 24 hours and
/// applied once in each phone's `seq` order (`mailbox.rs`, PROTOCOL.md "Store and forward").
/// `bundle-v1`: the `bundle` service (attachment `put` and file `get` as sealed
/// content-defined chunks, `bundle.rs`).
/// The names are declared once in `cmux_mobile_link::names`.
pub const CAPABILITIES: [&str; 13] = [
    names::REMOVAL,
    names::FILE_PREVIEW,
    names::LOCALHOST_FORWARD,
    names::CLOUD_DIRECTORY,
    names::CLOUD_ACPMUX,
    names::NEEDS_YOU,
    names::APPEARANCE,
    names::PAIR_REQUESTS,
    names::PHONE_FRAMES,
    names::TAB_SNAPSHOTS,
    names::PHONE_PAGE,
    names::MAILBOX_SEND,
    names::BUNDLE,
];
/// Added to [`CAPABILITIES`] when this Mac can stream browser tabs (`browser`).
pub const BROWSER_STREAM: &str = names::BROWSER_STREAM;
/// With [`BROWSER_STREAM`]: `browser {"video": "track"}` carries the page's
/// video on the link's media lane when the link has one.
pub const BROWSER_VIDEO_TRACK: &str = names::BROWSER_VIDEO_TRACK;
/// Added when this Mac streams its phone tabs' simulators (`surface`), with
/// `video: "track"` as for browser tabs.
pub const SURFACE_STREAM: &str = names::SURFACE_STREAM;
/// Added with [`SURFACE_STREAM`]: `surface` also streams the owner's own Cloud
/// machine desktop, view only (`c~<machine_id>~<team_id>`, `surface.rs`).
pub const CLOUD_DESKTOP: &str = names::CLOUD_DESKTOP;
/// Added when `surface` also streams this Mac's own displays, view only
/// (`d~<display>`, `surface.rs`): the Mac screen as rd/1 on the phone's link.
pub const MAC_DISPLAY: &str = names::MAC_DISPLAY;

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
    if config.surface.streams_mac_display() {
        out.push(MAC_DISPLAY);
    }
    if crate::site_data::enabled() && control::enabled() {
        out.push(names::SITE_DATA_HANDOFF);
    }
    if crate::lan::running() {
        // The phone may enroll for the LAN direct path (`lan`, lan.rs).
        out.push(crate::lan::CAPABILITY);
    }
    if crate::try_pr::available() {
        out.push(crate::try_pr::CAPABILITY);
    }
    out
}

/// Response on a version channel, including features enabled on this host.
pub fn version_reply(config: &ServiceConfig) -> Value {
    serde_json::json!({
        "hostd": env!("CARGO_PKG_VERSION"),
        // 2: control frames ahead of data, any frame counts as life, the
        // reader never stalls on one full channel, the `version` service.
        "link": LINK_PROTOCOL,
        // What this host does that a phone may rely on. `removal-v1`: once its owner
        // removes this Mac (4002 `removed`) it stays off until allowed again on the Mac.
        // `browser-stream-v1`: it streams browser tabs (`browser`).
        "capabilities": capabilities(config),
    })
}

async fn version(config: &ServiceConfig, sender: &ChannelSender) -> Result<(), Refusal> {
    let _ = sender.send(Bytes::from(version_reply(config).to_string())).await;
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
                // Whether a Cloud chat can open now (the app has the machine's live link). An
                // asleep machine is listed for the Chief's Computer card, never as a chat.
                "linked": link.socket.is_some(),
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
    let served = async {
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
        Ok::<(), Refusal>(())
    }
    .await;
    // However the channel ended, a start still in flight closes its empty tab on the machine
    // (best effort: the carrier may be gone too).
    let _ = apply_cloud_effects(&mut write, sender, adapter.abandon()).await;
    served
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
            "capabilities":[names::CLOUD_MOBILE_CHAT,names::CONVERSATION_TABS,names::AGENT_SESSION_TABS]}),
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
                .is_some_and(|caps| caps.iter().any(|cap| cap == names::CLOUD_MOBILE_CHAT))
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
    // A new phone asks for redraw ids (`"pseq": true`) and for viewport sync (`"viewport_sync": 1`);
    // an old one gets the plain stream.
    let pseq = args.get("pseq") == Some(&Value::Bool(true));
    let asked = args.get("viewport_sync").and_then(Value::as_u64) == Some(1);
    let sync = match (asked, &config.viewport_sync, &peer.viewport) {
        (true, Some(selector), Some(hub)) => Some((Arc::clone(hub), selector.clone())),
        _ => None,
    };
    splice(
        &path,
        session,
        LinePolicy::Daemon(
            DaemonPolicy::new(&peer.device_id).with_agent_tab_host(config.agent_tab_host.clone()),
        ),
        config.pairing.as_ref().map(|pairing| std::sync::Arc::clone(&pairing.spent_replies)),
        sender,
        receiver,
        peer.session_exposure.clone(),
        LineStamps { pseq, sync },
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
    let stamps = LineStamps { pseq: true, sync: None };
    splice(&path, "chief", LinePolicy::Chief(policy), None, sender, receiver, None, stamps).await
}

/// How a splice's daemon lines leave for the phone: stamped with redraw ids (`pseq`) or not,
/// and through a viewport sync (the link's port and the path selector's numbers) or not.
struct LineStamps {
    pseq: bool,
    sync: Option<(Arc<crate::viewport_link::LinkHub>, crate::viewport_sync::SelectorConfig)>,
}

/// Bound an unanswered ordered command; its splice closes on expiry. Terminal
/// sends, long-running `wait-for` reads and close handling never wait on this timer.
const SIDE_COMPLETION_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

/// Splices one phone channel to a daemon socket. Responses and refusals
/// reach the phone as whole lines, never interleaved.
#[allow(clippy::too_many_arguments)] // one splice: its socket, policies, channel, exposure and line stamps
async fn splice(
    path: &Path,
    label: &str,
    policy: LinePolicy,
    spent_replies: Option<std::sync::Arc<crate::mailbox::SpentReplies>>,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
    exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
    stamps: LineStamps,
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
    let daemon_exposure = exposure.clone();
    let request_exposure = daemon_exposure.clone();
    let answers = Arc::clone(&pending);
    // The daemon lane: when each output byte went to the phone (output_paint.rs).
    let output_stamps = reply_phone.as_deref().map(crate::output_paint::Tracker::start);
    let LineStamps { pseq, sync } = stamps;
    let mut viewport = sync.map(|(hub, selector)| {
        crate::viewport_link::ViewportLink::new(hub, selector, pseq, daemon_lines.clone())
    });
    let hybrid_marks = viewport.as_ref().map(crate::viewport_link::ViewportLink::hybrid_marks);
    let mut from_daemon = tokio::spawn(async move {
        let mut reader = BufReader::with_capacity(64 * 1024, daemon_read);
        loop {
            let mut line = Vec::new();
            match reader.read_until(b'\n', &mut line).await {
                Ok(0) | Err(_) => {
                    // Every sync's last lines, in order, before the stream ends.
                    if let Some(viewport) = &mut viewport {
                        let _ = viewport.finish().await;
                    }
                    return;
                }
                Ok(_) => {
                    // hostd's own releases: answered to hostd, not the phone.
                    if answers.answer(&line) {
                        continue;
                    }
                    let line = completed.answer(line);
                    let Some(line) = reply_policy.reply(line) else { continue };
                    let Some(line) = exposed_daemon_line(line, daemon_exposure.as_ref()) else { continue };
                    if let Some(viewport) = &mut viewport {
                        // Its own lines and this one, stamped when asked, in order.
                        if viewport.on_line(line).await.is_err() {
                            return;
                        }
                        continue;
                    }
                    // A redraw's id and its read time (Mac redraw to iPhone paint), when asked.
                    let line = crate::viewport_link::stamped(line, pseq);
                    if let Some(stamps) = &output_stamps {
                        stamps.line(&line);
                    }
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
            let verdict = daemon_owned_verdict(cache, &line, verdict).await;
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
                            if let Some(answer) = daemon_exposure_refusal(&line, request_exposure.as_ref()) {
                                if refusals.send(answer).await.is_err() { return; }
                                continue;
                            }
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
                let (checked, verdict) = daemon_line_verdict(&policy, line, request_exposure.as_ref());
                line = checked;
                // A hybrid attach's surface never syncs (its stream is not the PTY's bytes).
                if let Some(marks) = &hybrid_marks
                    && !matches!(verdict, Verdict::Refuse(_))
                {
                    marks.observe(&line);
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
                        request_exposure.as_ref(),
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
                    let Some(line) = exposed_daemon_line(line, exposure.as_ref()) else { continue };
                    let mark = crate::paint_latency::flush_mark(&line);
                    if sender.send_marked(Bytes::from(line), mark).await.is_err() {
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
                    if let Some(line) = exposed_daemon_line(line, exposure.as_ref()) {
                        let _ = sender.send(Bytes::from(line)).await;
                    }
                }
                break;
            }
            _ = &mut from_daemon => {
                while let Ok(line) = lines_rx.try_recv() {
                    if let Some(line) = exposed_daemon_line(line, exposure.as_ref()) {
                        let _ = sender.send(Bytes::from(line)).await;
                    }
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

/// The first check of one phone request line on a daemon lane (the `daemon` and `chief`
/// splices and `catch-up`): the chat exposure, then the lane's policy. The line to go on
/// (the Chief lane's re-serialized object) and its verdict; an exposure refusal is a
/// `Refuse`.
fn daemon_line_verdict(
    policy: &LinePolicy,
    line: Vec<u8>,
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
) -> (Vec<u8>, Verdict) {
    if let Some(answer) = daemon_exposure_refusal(&line, exposure) {
        let answer = String::from_utf8_lossy(answer.strip_suffix(b"\n").unwrap_or(&answer)).into_owned();
        return (line, Verdict::Refuse(answer));
    }
    let (verdict, canonical) = policy.evaluate(&line);
    (canonical.unwrap_or(line), verdict)
}

/// The daemon lane's ownership check of a request the policy let through: the cached
/// views it needs are read (waited for when cold), then [`owned_check`]. The splice's
/// side worker and `catch-up` both call this.
async fn daemon_owned_verdict(
    cache: &crate::workspace_cache::WorkspaceCache,
    line: &[u8],
    verdict: Verdict,
) -> Verdict {
    if let Some((tree, personal, layout)) = side_requirements(line) {
        cache.wait_for(tree, personal, layout).await;
    }
    owned_check(cache, line, verdict)
}

/// One read-only request a `catch-up` sends the daemon, checked as the `daemon` channel
/// checks the same line: [`daemon_line_verdict`] (exposure, then [`DaemonPolicy`]), then,
/// for a line that names something owned, [`daemon_owned_verdict`] against the live
/// workspace cache (a line that needs one and has none is refused), the Mac's folder for a
/// new tab, and the exposure once more. `Ok`: the bytes to send (with their newline);
/// `Err`: the refusal line the channel would have answered.
pub(crate) async fn checked_daemon_request(
    policy: &DaemonPolicy,
    cache: Option<&crate::workspace_cache::WorkspaceCache>,
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
    line: Vec<u8>,
) -> Result<Vec<u8>, String> {
    let (line, verdict) = daemon_line_verdict(&LinePolicy::Daemon(policy.clone()), line, exposure);
    let needs_cache = side_requirements(&line).is_some() || crate::policy::ownership(&line).is_some();
    let verdict = match (cache, needs_cache) {
        (Some(cache), _) => daemon_owned_verdict(cache, &line, verdict).await,
        (None, false) => verdict,
        (None, true) => {
            let request = serde_json::from_slice::<Value>(&line).ok();
            Verdict::Refuse(crate::policy::error_line(
                request.as_ref().and_then(|request| request.get("id")),
                "forbidden",
                "not available without the workspace cache",
            ))
        }
    };
    let line = match verdict {
        Verdict::Forward => line,
        Verdict::Rewrite(line) => line,
        Verdict::Refuse(answer) => return Err(answer),
    };
    let mut line = with_pane_folder(cache.and_then(|cache| cache.tree()).as_deref(), line);
    if let Some(answer) = daemon_exposure_refusal(&line, exposure) {
        return Err(String::from_utf8_lossy(answer.strip_suffix(b"\n").unwrap_or(&answer)).into_owned());
    }
    line.push(b'\n');
    Ok(line)
}

/// A daemon reply line as the `daemon` channel would pass it to the phone (the exposure's
/// reply filter, [`exposed_daemon_line`]); None when it would drop it.
pub(crate) fn exposed_daemon_reply(
    line: Vec<u8>,
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
) -> Option<Vec<u8>> {
    exposed_daemon_line(line, exposure)
}

/// Check again after the side worker's awaits and when draining queued replies.
/// A policy sampled at ingress cannot authorize a later write or publication.
fn daemon_exposure_refusal(
    line: &[u8],
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
) -> Option<Vec<u8>> {
    let exposure = exposure?;
    if !crate::acpmux_policy::daemon_request_blocked(&String::from_utf8_lossy(line), &exposure.borrow()) {
        return None;
    }
    let request = serde_json::from_slice::<Value>(line).ok();
    let mut answer = crate::policy::error_line(
        request.as_ref().and_then(|request| request.get("id")),
        "forbidden",
        "chat is not exposed",
    )
    .into_bytes();
    answer.push(b'\n');
    Some(answer)
}

fn exposed_daemon_line(
    line: Vec<u8>,
    exposure: Option<&tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
) -> Option<Vec<u8>> {
    let Some(exposure) = exposure else { return Some(line) };
    let state = exposure.borrow().clone();
    if !state.available {
        return None;
    }
    // Terminal streams also carry non-JSON lines, which have no chat projection.
    if serde_json::from_slice::<Value>(&line).is_err() {
        return Some(line);
    }
    crate::acpmux_policy::filter_daemon_response(&String::from_utf8_lossy(&line), &state)
        .map(|filtered| format!("{filtered}\n").into_bytes())
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
    // acpmux's own limits (its `WS_MAX_MESSAGE_BYTES`): tungstenite's default 16 MiB frame made
    // the push watcher drop an older acpmux's 24.8 MB watch list and ask again, about once a
    // minute for hours (2026-11-06).
    let limits = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(ACPMUX_MAX_MESSAGE_BYTES))
        .max_frame_size(Some(ACPMUX_MAX_MESSAGE_BYTES));
    let (socket, _) = cmux_egress::ws::connect_async_with_config(
        request,
        Some(limits),
        false,
        "cmux_mobile_host::services::acpmux",
    )
    .await
    .map_err(|e| Refusal::new("unavailable", format!("acpmux: {e}")))?;
    Ok(socket)
}

/// Session bindings the two halves of one `acpmux` relay share.
#[derive(Default)]
struct AcpmuxRelayState {
    bound_sessions: HashSet<String>,
    pending_new: HashSet<String>,
    server_reply_ids: std::collections::HashMap<String, String>,
}

/// What the relay does with one phone message ([`AcpmuxRelay::upstream`]).
pub(crate) enum Upstream {
    /// Send this (canonical, maybe marked) text to acpmux.
    Send(String),
    /// Answer the phone with this and send nothing to acpmux.
    Answer(String),
    /// The message's session ids could not be resolved now (not a refusal): answer the phone
    /// with this and send nothing to acpmux.
    Unresolved(String),
    /// The exposure changed under the relay, or became unreadable: end the relay.
    Close,
}

/// What the relay does with one acpmux text message ([`AcpmuxRelay::downstream`]).
pub(crate) enum Downstream {
    /// Send this (filtered) text to the phone.
    Send(String),
    /// Drop it (it names a chat the phone may not see).
    Skip,
    /// A chat this relay touched is no longer exposed: end the relay.
    Close,
}

/// The checks one `acpmux` relay applies to every message both ways: canonical session
/// ids, per-chat exposure, the asking-mode rule, Full-access marking on the phone's own
/// credential, and the reply filter. The `acpmux` channel and `catch-up`
/// (`catch_up.rs`) both call these, so a catch-up line passes exactly what the channel's
/// would.
pub(crate) struct AcpmuxRelay<'a> {
    target: &'a AcpmuxTarget,
    exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
    /// acpmux was reached on the phone's own credential (`control::phone_credential`).
    as_phone: bool,
    /// What both directions learn about the sessions this phone touches. Locked only for a
    /// moment, never across an await.
    shared: std::sync::Mutex<AcpmuxRelayState>,
}

impl<'a> AcpmuxRelay<'a> {
    pub(crate) fn new(
        target: &'a AcpmuxTarget,
        exposure: Option<tokio::sync::watch::Receiver<crate::control::SessionExposure>>,
        as_phone: bool,
    ) -> Self {
        Self { target, exposure, as_phone, shared: std::sync::Mutex::new(AcpmuxRelayState::default()) }
    }

    pub(crate) fn state(&self) -> crate::control::SessionExposure {
        self.exposure.as_ref().map(|receiver| receiver.borrow().clone()).unwrap_or_default()
    }

    /// Whether the relay must end now: the exposure is unreadable, or a chat it touched
    /// was turned off.
    pub(crate) fn closed(&self, state: &crate::control::SessionExposure) -> bool {
        let relay = self.shared.lock().expect("acpmux relay state");
        !state.available || relay.bound_sessions.iter().any(|session| state.blocked.contains(session))
    }

    /// Checks one phone message on its way to acpmux. `side` is hostd's own second
    /// connection for the mode check (`_acpmux/info`), opened on first use.
    pub(crate) async fn upstream(
        &self,
        side: &mut Option<AcpmuxSocket>,
        known: &mut CanonicalIds,
        text: &str,
    ) -> Upstream {
        let Some((text, dependencies)) = canonicalize_requests(self.target, text, known).await else {
            return Upstream::Unresolved(serde_json::json!({"jsonrpc":"2.0","id":null,"error":{"code":-32602,"message":"Session exposure could not be resolved"}}).to_string());
        };
        let state = self.state();
        if !state.available || dependencies.iter().any(|session| state.blocked.contains(session)) {
            return Upstream::Close;
        }
        let refusal = {
            let relay = self.shared.lock().expect("acpmux relay state");
            crate::acpmux_policy::exposure_refusal_with_replies(
                &text,
                &state,
                &relay.bound_sessions,
                &relay.server_reply_ids,
            )
        };
        if let Some(answer) = refusal {
            return Upstream::Answer(answer);
        }
        {
            let mut relay = self.shared.lock().expect("acpmux relay state");
            if let Ok(value) = serde_json::from_str::<Value>(&text) {
                let requests = match &value {
                    Value::Array(items) => items.iter().collect::<Vec<_>>(),
                    other => vec![other],
                };
                for request in requests {
                    if request
                        .get("method")
                        .and_then(Value::as_str)
                        .is_some_and(|method| method == "session/new" || method == "acp.session.new")
                        && let Some(id) = request.get("id")
                    {
                        relay.pending_new.insert(id.to_string());
                    }
                }
            }
            relay.bound_sessions.extend(dependencies);
            // Bind every accepted session-targeting request, not only
            // prompt/retry methods; info, events and mode changes also
            // keep a live channel's exposure alive.
            for (_, session) in crate::acpmux_policy::request_targets(&text) {
                relay.bound_sessions.insert(session.clone());
            }
        }
        // An agent a phone drives stays in a mode that asks
        // (`acpmux_policy`): a refused mode set is answered here.
        let refused = match crate::acpmux_policy::refusal(&text) {
            Some(answer) => Some(answer),
            None => match crate::acpmux_policy::controlled_session(&text) {
                Some((id, session)) => {
                    let mode = current_mode(self.target, side, &session).await;
                    crate::acpmux_policy::mode_refusal(&id, mode.as_deref())
                }
                None => None,
            },
        };
        // On the phone's own credential acpmux decides by its Full-access setting.
        let (text, refused) = match (refused, self.as_phone) {
            (Some(answer), true) => match crate::acpmux_policy::marked(&text) {
                Some(marked) => (marked, None),
                None => (text, Some(answer)),
            },
            (refused, _) => (text, refused),
        };
        if let Some(answer) = refused {
            return Upstream::Answer(answer);
        }
        let latest = self.state();
        let mut relay = self.shared.lock().expect("acpmux relay state");
        if !latest.available
            || relay.bound_sessions.iter().any(|session| latest.blocked.contains(session))
            || crate::acpmux_policy::exposure_refusal_with_replies(
                &text,
                &latest,
                &relay.bound_sessions,
                &relay.server_reply_ids,
            )
            .is_some()
        {
            return Upstream::Close;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&text) {
            let methodless = match &value {
                Value::Array(items) => items.iter().all(|item| item.get("method").is_none()),
                other => other.get("method").is_none(),
            };
            if methodless {
                for id in crate::acpmux_policy::response_ids(&text) {
                    relay.server_reply_ids.remove(&id);
                }
            }
        }
        Upstream::Send(text)
    }

    /// Checks one acpmux text message on its way to the phone.
    pub(crate) fn downstream(&self, text: &str) -> Downstream {
        let state = self.state();
        let mut relay = self.shared.lock().expect("acpmux relay state");
        if !state.available || relay.bound_sessions.iter().any(|session| state.blocked.contains(session)) {
            return Downstream::Close;
        }
        for (id, session) in crate::acpmux_policy::returned_sessions(text) {
            if relay.pending_new.remove(&id) {
                relay.bound_sessions.insert(session);
            }
        }
        let Some(text) = crate::acpmux_policy::filter_response(text, &state, &relay.bound_sessions) else {
            return Downstream::Skip;
        };
        if let Ok(value) = serde_json::from_str::<Value>(&text) {
            let requests = match &value {
                Value::Array(items) => items.iter().collect::<Vec<_>>(),
                other => vec![other],
            };
            for request in requests {
                if request.get("method").is_some() {
                    for (id, session) in crate::acpmux_policy::request_targets(&request.to_string()) {
                        relay.bound_sessions.insert(session.clone());
                        relay.server_reply_ids.insert(id, session);
                    }
                }
            }
        }
        Downstream::Send(text)
    }
}

/// The acpmux connection a phone's channel uses: on the phone's own credential when the app
/// gave it one and acpmux takes it (true), else the dashboard token (false).
pub(crate) async fn connect_for_phone(
    target: &AcpmuxTarget,
    device_id: &str,
) -> Result<(AcpmuxSocket, bool), Refusal> {
    let credential = control::phone_credential(device_id);
    let own = match credential.as_deref() {
        Some(credential) => connect_acpmux_as(target, Some(credential)).await.ok(),
        None => None,
    };
    match own {
        Some(socket) => Ok((socket, true)),
        None => Ok((connect_dashboard(target).await?, false)),
    }
}

/// `acpmux`: splice to the acpmux loopback WebSocket. One link data frame
/// carries one WebSocket text message in each direction.
///
/// A phone the app gave its own acpmux credential (`control::phone_credential`) connects
/// with it, so acpmux knows which phone it is (still a Web connection, with every Web
/// rule). What `acpmux_policy` refuses then goes on marked, and acpmux runs it only when
/// that phone's Full-access setting (Settings > Devices on the Mac, off by default)
/// covers it. Without a credential, or when acpmux refuses it, the dashboard token and
/// the refusal here stay as they were. Every message passes [`AcpmuxRelay`].
async fn acpmux(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
) -> Result<(), Refusal> {
    if let Some(exposure) = &peer.session_exposure
        && !exposure.borrow().available
    {
        return Err(Refusal::new("forbidden", "session exposure state is unavailable"));
    }
    let (socket, as_phone) = connect_for_phone(&config.acpmux, &peer.device_id).await?;
    let (mut ws_sink, mut ws_source) = socket.split();
    // The phone reads compressed envelopes (`link_deflate.rs`, CMUX-563).
    let deflate = crate::link_deflate::asked(args);
    let mut message = MessageAssembler::default();
    let relay = AcpmuxRelay::new(&config.acpmux, peer.session_exposure.clone(), as_phone);
    let relay = &relay;
    // A second connection of hostd's own, for `_acpmux/info` (the mode check).
    let mut side: Option<AcpmuxSocket> = None;
    // Session ids acpmux already answered as their own canonical id on this link. A current
    // phone names chats by canonical id, so its later requests skip the per-request trusted
    // side socket and `_acpmux/info`; an alias (an older phone) still resolves every time.
    let mut canonical_ids = CanonicalIds::default();
    // Two independent halves (contract point 5, input never head-of-line blocked behind
    // bulk): a big frame waiting for room toward the phone (`downstream`) no longer stops
    // `upstream` reading the phone's next prompt. When either half ends, the other is
    // dropped and the socket closed.
    let upstream = async {
        loop {
            let event = receiver.recv().await;
            match event {
                Some(ChannelEvent::Data(bytes)) => {
                    let Some(text) = message.push(&bytes)? else { continue };
                    match relay.upstream(&mut side, &mut canonical_ids, &text).await {
                        Upstream::Send(text) => {
                            if ws_sink.send(Message::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        Upstream::Answer(answer) | Upstream::Unresolved(answer) => {
                            if sender.send(Bytes::from(answer.into_bytes())).await.is_err() {
                                break;
                            }
                        }
                        Upstream::Close => break,
                    }
                }
                _ => break,
            }
        }
        Ok::<(), Refusal>(())
    };
    let downstream = async {
        loop {
            match ws_source.next().await {
                Some(Ok(Message::Text(text))) => {
                    let filtered = match relay.downstream(&text) {
                        Downstream::Send(text) => text,
                        Downstream::Skip => continue,
                        Downstream::Close => break,
                    };
                    if sender.send(crate::link_deflate::frame(deflate, &filtered).await).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Binary(bytes))) => {
                    let state = relay.state();
                    if state.configured || !state.available {
                        break;
                    }
                    if sender.send(bytes).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            }
        }
    };
    let exposure_watch = async {
        let mut exposure = peer.session_exposure.clone();
        let Some(exposure) = exposure.as_mut() else { return std::future::pending::<()>().await };
        loop {
            if exposure.changed().await.is_err() {
                return;
            }
            let state = exposure.borrow().clone();
            if relay.closed(&state) {
                return;
            }
        }
    };
    let outcome = tokio::select! {
        outcome = upstream => outcome,
        () = downstream => Ok(()),
        () = exposure_watch => Ok(()),
    };
    // The unfinished halves are dropped by the select; now the socket can close.
    let _ = ws_sink.close().await;
    outcome
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

/// Resolve aliases over a fresh trusted side socket. A fresh request id and
/// socket prevent a timed-out info reply from authorizing another target.
async fn trusted_session_query(target: &AcpmuxTarget, method: &str, params: Value) -> Option<Value> {
    let query = async {
        let mut socket = connect_acpmux(target).await.ok()?;
        let id = uuid::Uuid::new_v4().to_string();
        let request = serde_json::json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
        socket.send(Message::Text(request.to_string().into())).await.ok()?;
        while let Some(Ok(Message::Text(text))) = socket.next().await {
            let Ok(reply) = serde_json::from_str::<Value>(&text) else { continue };
            if reply.get("id").and_then(Value::as_str) != Some(&id) {
                continue;
            }
            return reply.get("result").cloned();
        }
        None
    };
    tokio::time::timeout(std::time::Duration::from_secs(5), query).await.ok().flatten()
}

/// Ids acpmux resolved to themselves on one phone link. A canonical session id never
/// becomes an alias of another session, so it needs no second trusted lookup; exposure is
/// still checked on every request against the canonical id. Bounded: past the cap it starts
/// over, which only costs lookups again.
#[derive(Default)]
pub(crate) struct CanonicalIds(HashSet<String>);

impl CanonicalIds {
    const CAP: usize = 4096;

    fn contains(&self, session: &str) -> bool {
        self.0.contains(session)
    }

    fn insert(&mut self, session: String) {
        if self.0.len() >= Self::CAP {
            self.0.clear();
        }
        self.0.insert(session);
    }
}

async fn canonical_session(target: &AcpmuxTarget, session: &str, known: &mut CanonicalIds) -> Option<String> {
    if known.contains(session) {
        return Some(session.to_owned());
    }
    let canonical = trusted_session_query(
        target,
        "_acpmux/info",
        serde_json::json!({"sessionId":session,"waitLogs":false}),
    )
    .await?
    .get("sessionId")?
    .as_str()
    .map(str::to_owned)?;
    if canonical == session {
        known.insert(canonical.clone());
    }
    Some(canonical)
}

async fn canonicalize_requests(
    target: &AcpmuxTarget,
    text: &str,
    known: &mut CanonicalIds,
) -> Option<(String, HashSet<String>)> {
    let mut value = serde_json::from_str::<Value>(text).ok()?;
    let mut dependencies = HashSet::new();
    let requests = match &mut value {
        Value::Array(items) => items.iter_mut().collect::<Vec<_>>(),
        other => vec![other],
    };
    for request in requests {
        if request.get("method").is_none() || crate::acpmux_policy::global_request(request) {
            continue;
        }
        let indirect = request.get("method").and_then(Value::as_str).is_some_and(|method| {
            matches!(
                method,
                "_acpmux/handoff_get"
                    | "_acpmux/handoff_draft"
                    | "_acpmux/handoff_start"
                    | "_acpmux/handoff_discard"
            )
        });
        let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else { continue };
        let named = ["sessionId", "session", "name"]
            .iter()
            .filter_map(|key| params.get(*key).and_then(Value::as_str))
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if named.windows(2).any(|pair| pair[0] != pair[1]) {
            return None;
        }
        // A handoff id is an indirect capability: resolve both sides using the
        // trusted record, never a phone-supplied target. Its source capsule is
        // protected as well as the target that start/discard can mutate.
        let handoff_target = if indirect {
            if let Some(handoff_id) = params.get("handoffId").and_then(Value::as_str) {
                let handoff = trusted_session_query(
                    target,
                    "_acpmux/handoff_get",
                    serde_json::json!({"handoffId":handoff_id}),
                )
                .await?;
                let source = handoff.pointer("/source/sessionId")?.as_str()?.to_owned();
                let destination = handoff.pointer("/target/sessionId")?.as_str()?.to_owned();
                dependencies.insert(source);
                dependencies.insert(destination.clone());
                Some(destination)
            } else {
                None
            }
        } else {
            None
        };
        let canonical = match (named.first(), handoff_target) {
            (Some(named), Some(destination)) => {
                if canonical_session(target, named, known).await? != destination {
                    return None;
                }
                destination
            }
            (None, Some(destination)) => destination,
            (Some(named), None) => canonical_session(target, named, known).await?,
            (None, None) => continue,
        };
        for key in ["sessionId", "session", "name"] {
            params.remove(key);
        }
        params.insert("sessionId".into(), Value::String(canonical));
    }
    Some((value.to_string(), dependencies))
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

/// The regular file `args.path` names, opened inside the shared roots (the Chat Folders, then the
/// Mac's workspace folders as they are now), checked again where the open descriptor points. `file`,
/// `file-preview` and `bundle` `get` read only through it.
pub(crate) async fn open_shared_file(
    config: &ServiceConfig,
    args: &Value,
) -> Result<(tokio::fs::File, std::fs::Metadata), Refusal> {
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
    Ok((file, metadata))
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
    let (file, metadata) = open_shared_file(config, args).await?;
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

/// The surface check's query: page records (`page-tabs-v1`), then `list-workspaces`.
fn surface_query() -> String {
    format!(
        "{{\"cmd\":\"set-client-info\",\"id\":\"cmux-mobile-surface-hello\",\"name\":\"cmux-mobile-host\",\"kind\":\"cli\",\"capabilities\":[\"{}\",\"{}\"]}}\n{{\"cmd\":\"list-workspaces\",\"id\":\"cmux-mobile-surface\"}}\n",
        names::CONVERSATION_TABS,
        names::PAGE_TABS
    )
}

/// A phone tab is one this Mac's daemon lists now (`list-workspaces`); no
/// answer streams nothing.
impl crate::surface::SurfaceTabs for ServiceConfig {
    fn is_phone_tab(&self, surface: u64) -> futures_util::future::BoxFuture<'_, bool> {
        Box::pin(async move {
            // Page tabs read as their record (`conversation.page`) only for a client
            // that negotiated `page-tabs-v1`; without it every page tab reads `browser`.
            daemon_query(&self.daemon_socket(), surface_query().as_bytes(), "cmux-mobile-surface")
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
pub(crate) async fn daemon_query(path: &Path, request: &[u8], id: &str) -> Result<Value, Refusal> {
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
/// it without leaving its folder. Without: `<uploads>/<session>`. Resumable
/// uploads use a per-phone directory in place of the link session.
async fn upload_folder(
    config: &ServiceConfig,
    peer: &Peer,
    cwd: Option<&str>,
    resumable: bool,
) -> Result<PathBuf, Refusal> {
    let session: String =
        peer.session_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(36).collect();
    if session.is_empty() {
        return Err(Refusal::new("bad_request", "no link session"));
    }
    // The link's session id changes on redial. Scope resumable parts to this phone
    // across links, without putting a peer-supplied path component on disk.
    let scope = if resumable {
        format!("device-{:x}", Sha256::digest(peer.device_id.to_ascii_lowercase().as_bytes()))
    } else {
        session
    };
    let Some(cwd) = cwd else {
        let folder = config.uploads_dir.join(&scope);
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
    // The daemon is asked only for a folder outside the roots (`daemon_query` bounds it at
    // 5 s, `unavailable`, on which the phone falls back to the uploads folder).
    if !in_roots && !daemon_folders(config).await?.contains(&canonical) {
        return Err(Refusal::new("forbidden", "cwd is not the folder of a tab on this Mac"));
    }
    let folder = canonical.join(".cmux").join("attachments").join(format!("phone-{scope}"));
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

/// Keep resumable bytes inside the authorized publish folder and partition them
/// by authenticated device, even when two publish folders resolve to one alias.
/// A link session may change on redial; the device identity must not.
fn upload_parts_dir(folder: &Path, device_id: &str) -> Result<PathBuf, Refusal> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let folder = std::fs::canonicalize(folder).map_err(|e| Refusal::new("io", e.to_string()))?;
    let parts =
        folder.join(format!(".parts-{:x}", Sha256::digest(device_id.to_ascii_lowercase().as_bytes())));
    match std::fs::DirBuilder::new().mode(0o700).create(&parts) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(Refusal::new("io", format!("cannot create the upload parts: {e}"))),
    }
    // Refuse aliases instead of allowing one phone's staging directory to point
    // at another's. Open before changing permissions so a symlink is never chmod'ed.
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(&parts)
        .map_err(|_| Refusal::new("forbidden", "the upload parts must be a private directory"))?;
    directory
        .set_permissions(std::fs::Permissions::from_mode(0o700))
        .map_err(|e| Refusal::new("io", e.to_string()))?;
    let resolved = std::fs::canonicalize(&parts).map_err(|_| Refusal::new("io", "upload parts vanished"))?;
    if resolved.parent() != Some(folder.as_path()) {
        return Err(Refusal::new("forbidden", "the upload parts leave the upload folder"));
    }
    Ok(resolved)
}

pub(crate) fn create_private_dir(path: &Path) -> Result<(), Refusal> {
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path) {
        Ok(()) => Ok(()),
        Err(e) => Err(Refusal::new("io", format!("cannot create {}: {e}", path.display()))),
    }
}

/// `<folder>/<name>`, or `<stem> 2.<ext>`, ... when that name is taken:
/// links `part` there without replacing anything.
pub(crate) fn publish_upload(folder: &Path, name: &str, part: &Path) -> Result<PathBuf, Refusal> {
    let path = link_upload(folder, name, part)?;
    let _ = std::fs::remove_file(part);
    Ok(path)
}

fn upload_candidate(folder: &Path, name: &str, attempt: usize) -> PathBuf {
    if attempt == 1 {
        return folder.join(name);
    }
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    folder.join(format!("{stem} {attempt}{extension}"))
}

fn link_upload(folder: &Path, name: &str, part: &Path) -> Result<PathBuf, Refusal> {
    for attempt in 1..=999 {
        let candidate = upload_candidate(folder, name, attempt);
        match std::fs::hard_link(part, &candidate) {
            Ok(()) => return Ok(candidate),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(Refusal::new("io", format!("cannot save the upload: {e}"))),
        }
    }
    Err(Refusal::new("io", "too many files with that name"))
}

/// A completed upload remains replayable if its final reply was lost. The
/// record is private, device-scoped, and binds to the published inode, not just
/// a filename that the user might later replace.
#[derive(serde::Serialize, serde::Deserialize)]
struct UploadCompletion {
    name: String,
    size: u64,
    file: String,
    device: u64,
    inode: u64,
    sha256: String,
}

fn completed_upload(
    receipt: &Path,
    folder: &Path,
    name: &str,
    size: u64,
    hash: Option<&str>,
) -> Result<Option<PathBuf>, Refusal> {
    use std::io::Read;
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(receipt)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Refusal::new("io", e.to_string())),
    };
    let meta = file.metadata().map_err(|e| Refusal::new("io", e.to_string()))?;
    if !meta.is_file() || meta.nlink() != 1 || meta.len() > 4096 {
        return Err(Refusal::new("io", "invalid upload completion"));
    }
    let done: UploadCompletion = serde_json::from_reader(file.take(4097))
        .map_err(|_| Refusal::new("io", "invalid upload completion"))?;
    if done.name != name || done.size != size || hash.is_some_and(|hash| hash != done.sha256) {
        return Err(Refusal::new("bad_request", "upload_id already completed a different file"));
    }
    if Path::new(&done.file).file_name().and_then(|name| name.to_str()) != Some(done.file.as_str()) {
        return Err(Refusal::new("io", "invalid completed upload path"));
    }
    let path = folder.join(&done.file);
    let meta = std::fs::symlink_metadata(&path)
        .map_err(|_| Refusal::new("not_found", "the completed upload is no longer present"))?;
    if !meta.is_file()
        || meta.len() != size
        || (meta.dev(), meta.ino()) != (done.device, done.inode)
        || file_sha256(&path).as_deref() != Some(done.sha256.as_str())
    {
        return Err(Refusal::new("io", "the completed upload changed"));
    }
    Ok(Some(path))
}

/// Write a complete receipt before making it visible. A crash during the write
/// leaves only an unreferenced temporary file; a retry never reads partial JSON.
fn record_upload_completion(
    receipt: &Path,
    path: &Path,
    name: &str,
    size: u64,
    hash: &str,
) -> Result<(), Refusal> {
    use std::io::Write;
    let io_error = |e: std::io::Error| Refusal::new("io", e.to_string());
    let meta = std::fs::symlink_metadata(path).map_err(io_error)?;
    if !meta.is_file() || meta.len() != size {
        return Err(Refusal::new("io", "the completed upload changed"));
    }
    let done = UploadCompletion {
        name: name.into(),
        size,
        file: path.file_name().unwrap().to_string_lossy().into_owned(),
        device: meta.dev(),
        inode: meta.ino(),
        sha256: hash.into(),
    };
    let temporary = receipt.with_extension(format!("{}.part", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut record = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)
            .map_err(io_error)?;
        record
            .write_all(&serde_json::to_vec(&done).map_err(|e| Refusal::new("io", e.to_string()))?)
            .map_err(io_error)?;
        record.sync_all().map_err(io_error)?;
        std::fs::rename(&temporary, receipt).map_err(io_error)?;
        std::fs::File::open(receipt.parent().unwrap()).and_then(|dir| dir.sync_all()).map_err(io_error)
    })();
    let _ = std::fs::remove_file(&temporary);
    result
}

fn publish_resumable_upload(
    folder: &Path,
    name: &str,
    part: &Path,
    receipt: &Path,
    size: u64,
    hash: Option<&str>,
) -> Result<PathBuf, Refusal> {
    let io_error = |e: std::io::Error| Refusal::new("io", e.to_string());
    let meta = std::fs::symlink_metadata(part).map_err(io_error)?;
    if !meta.is_file() || meta.len() != size {
        return Err(Refusal::new("io", "the upload part changed"));
    }
    let actual = file_sha256(part).ok_or_else(|| Refusal::new("io", "cannot hash upload"))?;
    if hash.is_some_and(|hash| hash != actual) {
        return Err(Refusal::new("bad_request", "upload sha256 does not match its bytes"));
    }
    let path = match meta.nlink() {
        1 => link_upload(folder, name, part)?,
        // The process stopped after publication but before recording completion.
        // Recover the exact published inode, with the same bounded name search
        // as publication; never link it a second time or scan the whole folder.
        2 => (1..=999)
            .map(|attempt| upload_candidate(folder, name, attempt))
            .find(|candidate| {
                std::fs::symlink_metadata(candidate).is_ok_and(|saved| {
                    saved.is_file() && (saved.dev(), saved.ino()) == (meta.dev(), meta.ino())
                })
            })
            .ok_or_else(|| Refusal::new("io", "cannot locate published upload"))?,
        _ => return Err(Refusal::new("io", "unexpected upload part links")),
    };
    // Make the published link durable before the completion record can outlive it.
    std::fs::File::open(folder).and_then(|dir| dir.sync_all()).map_err(io_error)?;
    record_upload_completion(receipt, &path, name, size, &actual)?;
    std::fs::remove_file(part).map_err(io_error)?;
    Ok(path)
}

/// `upload` `{name, size, cwd?}`: the phone sends exactly `size` bytes as
/// data frames; hostd writes them to a new file of the upload folder
/// ([`upload_folder`]) and answers one data frame `{"path","size"}`, then
/// closes with `eof`. A refusal is answered `{"error","message"}` before the
/// channel closes with that code. Legacy uploads remove an incomplete part.
/// Resumable uploads retain it for a later attempt. Nothing is overwritten,
/// nothing is executed, and any `size` is accepted: the bytes stream to disk
/// as they arrive (attachments have no size cap). `size` may be a JSON number
/// or a decimal string (the app's channel arguments are strings).
async fn upload(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    receiver: ChannelReceiver,
    stall_timeout: Duration,
) -> Result<(), Refusal> {
    let resumable = args.get("upload_id").is_some();
    match receive_upload(config, peer, args, sender, receiver, stall_timeout).await {
        Ok(Received { path, size, deduped }) => {
            tracing::info!(size, deduped, phone = peer.device_id, "upload saved");
            let mut reply = serde_json::json!({"path": path.to_string_lossy(), "size": size});
            if deduped {
                reply["deduped"] = true.into();
            }
            let mut reply = reply.to_string();
            if resumable {
                reply.push('\n');
            }
            let _ = sender.send(Bytes::from(reply)).await;
            Ok(())
        }
        Err(refusal) => {
            if resumable && refusal.code == "resume_gap" {
                return Err(refusal);
            }
            let mut reply = serde_json::json!({"error": refusal.code, "message": refusal.reason}).to_string();
            if resumable {
                reply.push('\n');
            }
            let _ = sender.send(Bytes::from(reply)).await;
            Err(refusal)
        }
    }
}

/// A finished upload: where it is, and whether it was a stored copy (no bytes crossed).
struct Received {
    path: PathBuf,
    size: u64,
    deduped: bool,
}

/// An `upload`'s (or a `bundle` `put`'s) `{name, size, cwd?}`: the safe file name, the declared size
/// and the folder it lands in ([`upload_folder`]).
fn upload_name_size(args: &Value) -> Result<(String, u64), Refusal> {
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
    Ok((name, size))
}

pub(crate) async fn upload_target(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
) -> Result<(String, u64, PathBuf), Refusal> {
    let (name, size) = upload_name_size(args)?;
    let cwd = args.get("cwd").and_then(Value::as_str).filter(|cwd| !cwd.is_empty());
    // A resumable upload (`upload_id`) lands in the phone's device-keyed folder, so a redial
    // on a new link session finds the same folder and part.
    let resumable = args.get("upload_id").is_some();
    let folder = upload_folder(config, peer, cwd, resumable).await?;
    Ok((name, size, folder))
}

async fn receive_upload(
    config: &ServiceConfig,
    peer: &Peer,
    args: &Value,
    sender: &ChannelSender,
    mut receiver: ChannelReceiver,
    stall_timeout: Duration,
) -> Result<Received, Refusal> {
    let (name, size) = upload_name_size(args)?;
    if let Some(value) = args.get("upload_id") {
        let id = value
            .as_str()
            .filter(|id| {
                id.len() == 36 && id.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f' | b'-'))
            })
            .ok_or_else(|| Refusal::new("bad_request", "invalid upload_id"))?;
        let offset = match args.get("offset") {
            None => Some(0),
            Some(Value::String(s)) if s.bytes().all(|b| b.is_ascii_digit()) => s.parse().ok(),
            Some(value) => value.as_u64(),
        }
        .ok_or_else(|| Refusal::new("bad_request", "invalid offset"))?;
        // Validate the request before either completed-upload replay or dedup
        // can return a path without consuming a payload.
        if offset > size {
            return Err(Refusal::new("bad_request", "offset exceeds the declared size"));
        }
        let sha256 = match args.get("sha256") {
            None => None,
            Some(value) => Some(
                value
                    .as_str()
                    .filter(|hash| hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()))
                    .map(str::to_ascii_lowercase)
                    .ok_or_else(|| Refusal::new("bad_request", "invalid sha256"))?,
            ),
        };
        let (_, _, folder) = upload_target(config, peer, args).await?;
        let parts = upload_parts_dir(&folder, &peer.device_id)?;
        cleanup_stale_upload_parts(&parts);
        let part = parts.join(format!(".{id}.part"));
        let io_error = |e: std::io::Error| Refusal::new("io", e.to_string());
        // Drop the descriptor before waking a retry, including on cancellation.
        let _release;
        let raw = open_upload_part(&part).await?;
        _release = UploadLockRelease;
        let receipt = parts.join(format!(".{id}.done"));
        let replay = {
            let (receipt, folder, name, hash) =
                (receipt.clone(), folder.clone(), name.clone(), sha256.clone());
            tokio::task::spawn_blocking(move || {
                let result = completed_upload(&receipt, &folder, &name, size, hash.as_deref());
                (raw, result)
            })
            .await
            .map_err(|e| Refusal::new("io", e.to_string()))?
        };
        let (raw, replay) = replay;
        if let Some(path) = replay? {
            let _ = std::fs::remove_file(&part);
            let _ = sender.send(Bytes::from(format!("{{\"have\":{size}}}\n"))).await;
            return Ok(Received { path, size, deduped: false });
        }
        let meta = raw.metadata().map_err(io_error)?;
        if !meta.is_file() || !matches!(meta.nlink(), 1 | 2) {
            return Err(Refusal::new("io", "the upload part must be a regular file with one link"));
        }
        // A preceding writer may have published and unlinked this inode between open and lock.
        let named =
            std::fs::symlink_metadata(&part).map_err(|_| Refusal::new("busy", "upload part changed"))?;
        if (named.dev(), named.ino()) != (meta.dev(), meta.ino()) {
            return Err(Refusal::new("busy", "upload part changed"));
        }
        if meta.nlink() == 2 {
            let (folder, name, part, receipt, hash) =
                (folder.clone(), name.clone(), part.clone(), receipt.clone(), sha256.clone());
            let path = tokio::task::spawn_blocking(move || {
                // Keep the writer's lock throughout recovery and cleanup.
                let _lock = raw;
                publish_resumable_upload(&folder, &name, &part, &receipt, size, hash.as_deref())
            })
            .await
            .map_err(|e| Refusal::new("io", e.to_string()))??;
            let _ = sender.send(Bytes::from(format!("{{\"have\":{size}}}\n"))).await;
            return Ok(Received { path, size, deduped: false });
        }
        let mut file = tokio::fs::File::from_std(raw);
        confine_open(std::slice::from_ref(&parts), &file)?;
        let index = upload_index_dir(&parts, &folder);
        if let (Some(hash), Some(index)) = (&sha256, &index)
            && UPLOAD_DEDUP.load(std::sync::atomic::Ordering::Relaxed)
            && let Some(stored) = dedup_lookup(index, &folder, hash, size).await
        {
            // The part this upload may have begun is not needed any more (it is ours: locked, one link).
            record_upload_completion(&receipt, &stored, &name, size, hash)?;
            let _ = std::fs::remove_file(&part);
            return Ok(Received { path: stored, size, deduped: true });
        }
        let length = meta.len();
        if offset > length {
            let _ =
                sender.send(Bytes::from(format!("{{\"error\":\"resume_gap\",\"have\":{length}}}\n"))).await;
            return Err(Refusal::new("resume_gap", format!("the upload has {length} bytes")));
        }
        file.set_len(offset).await.map_err(io_error)?;
        file.seek(SeekFrom::Start(offset)).await.map_err(io_error)?;
        let _ = sender.send(Bytes::from(format!("{{\"have\":{offset}}}\n"))).await;
        let mut received = offset;
        let mut last_ack = offset;
        while received < size {
            let data = async {
                loop {
                    match receiver.recv().await {
                        Some(ChannelEvent::Data(bytes)) if bytes.is_empty() => continue,
                        event => return event,
                    }
                }
            };
            let bytes = match timeout(stall_timeout, data).await {
                Ok(Some(ChannelEvent::Data(bytes))) => bytes,
                ended => {
                    file.flush().await.map_err(io_error)?;
                    file.sync_data().await.map_err(io_error)?;
                    send_upload_ack(sender, received).await;
                    return Err(if ended.is_err() {
                        Refusal::new("stalled", "upload stalled waiting for data")
                    } else {
                        Refusal::new("bad_request", "the upload ended early")
                    });
                }
            };
            if bytes.len() as u64 > size - received {
                let _ = std::fs::remove_file(&part);
                return Err(Refusal::new("bad_request", "more bytes than the declared size"));
            }
            file.write_all(&bytes).await.map_err(io_error)?;
            received += bytes.len() as u64;
            // An ack means durable: each MiB is synced as it lands, so a Mac that crashes or loses
            // power never loses bytes the phone was told it has, and the final answer below waits on
            // the last MiB at most instead of syncing the whole file.
            if received < size && received - last_ack >= UPLOAD_ACK_BYTES {
                file.flush().await.map_err(io_error)?;
                file.sync_data().await.map_err(io_error)?;
                send_upload_ack(sender, received).await;
                last_ack = received;
            }
        }
        file.flush().await.map_err(io_error)?;
        file.sync_data().await.map_err(io_error)?;
        send_upload_ack(sender, received).await;
        let path = {
            let (folder, name, part, receipt, hash) =
                (folder.clone(), name.clone(), part.clone(), receipt.clone(), sha256.clone());
            tokio::task::spawn_blocking(move || {
                let _lock = file;
                publish_resumable_upload(&folder, &name, &part, &receipt, size, hash.as_deref())
            })
            .await
            .map_err(|e| Refusal::new("io", e.to_string()))??
        };
        if let (Some(hash), Some(index)) = (&sha256, &index) {
            dedup_record(index, hash, &path);
        }
        return Ok(Received { path, size, deduped: false });
    }
    let (_, _, folder) = upload_target(config, peer, args).await?;
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
    Ok(Received { path, size, deduped: false })
}

/// Whole-file dedup (PROTOCOL.md `upload`, `sha256`). Off only in tests that play a Mac from
/// before it (an older hostd ignores the field).
#[doc(hidden)]
pub static UPLOAD_DEDUP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

/// The dedup index of one upload folder: `<parts>/.sha256-<folder name>/<sha256>`, each entry a
/// file holding the stored file's name in that folder. One file per hash, so a lookup or a record
/// costs the same at any number of uploads, and the index lives as long as the folder's files.
/// Scoped to the folder (one phone, one workspace): a phone never learns of another's files.
fn upload_index_dir(parts: &Path, folder: &Path) -> Option<PathBuf> {
    let name = folder.file_name()?.to_str()?;
    Some(parts.join(format!(".sha256-{name}")))
}

const MAX_DEDUP_ENTRY_BYTES: usize = 4096;

fn dedup_name(name: &str) -> Option<std::ffi::CString> {
    if name.is_empty() || name == "." || name == ".." || name.as_bytes().contains(&b'/') {
        return None;
    }
    std::ffi::CString::new(name).ok()
}

fn dedup_index_name(index: &Path) -> Option<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;

    let name = index.file_name()?;
    if name.is_empty() || name == "." || name == ".." || name.as_bytes().contains(&b'/') {
        return None;
    }
    std::ffi::CString::new(name.as_bytes()).ok()
}

/// Open the index directory through its parts directory, refusing aliases at both final components.
fn open_dedup_index(index: &Path, create: bool) -> Option<std::fs::File> {
    use std::os::fd::{AsRawFd, FromRawFd};

    let parent = index.parent()?;
    let name = dedup_index_name(index)?;
    let parent = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(parent)
        .ok()?;
    if create {
        let result = unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) };
        if result == -1 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
            return None;
        }
    }
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd == -1 {
        return None;
    }
    // SAFETY: `fd` is the owned descriptor returned by openat.
    Some(unsafe { std::fs::File::from_raw_fd(fd) })
}

fn open_dedup_entry(index: &std::fs::File, name: &str) -> Option<std::fs::File> {
    use std::os::fd::{AsRawFd, FromRawFd};

    let name = dedup_name(name)?;
    let fd = unsafe {
        libc::openat(index.as_raw_fd(), name.as_ptr(), libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK)
    };
    if fd == -1 {
        return None;
    }
    // SAFETY: `fd` is the owned descriptor returned by openat.
    Some(unsafe { std::fs::File::from_raw_fd(fd) })
}

fn remove_dedup_entry(index: &std::fs::File, name: &str) {
    use std::os::fd::AsRawFd;

    let Some(name) = dedup_name(name) else { return };
    let _ = unsafe { libc::unlinkat(index.as_raw_fd(), name.as_ptr(), 0) };
}

/// The SHA-256 of a regular file, not following a symlink.
fn file_sha256(path: &Path) -> Option<String> {
    use std::io::Read;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        match file.read(&mut buffer).ok()? {
            0 => break,
            n => hasher.update(&buffer[..n]),
        }
    }
    Some(format!("{:x}", hasher.finalize()))
}

/// The stored file the index names for `hash`, when it is still a regular file in `folder` of
/// `size` bytes whose content hashes to `hash`. A stale entry (moved, deleted, changed) is removed.
async fn dedup_lookup(index: &Path, folder: &Path, hash: &str, size: u64) -> Option<PathBuf> {
    let (index, folder, hash) = (index.to_path_buf(), folder.to_path_buf(), hash.to_string());
    tokio::task::spawn_blocking(move || {
        use std::io::Read;

        let index = open_dedup_index(&index, false)?;
        let entry = open_dedup_entry(&index, &hash)?;
        let metadata = entry.metadata().ok()?;
        if !metadata.is_file() || metadata.len() > MAX_DEDUP_ENTRY_BYTES as u64 {
            remove_dedup_entry(&index, &hash);
            return None;
        }
        let mut bytes = Vec::with_capacity(MAX_DEDUP_ENTRY_BYTES + 1);
        if entry.take((MAX_DEDUP_ENTRY_BYTES + 1) as u64).read_to_end(&mut bytes).is_err()
            || bytes.len() > MAX_DEDUP_ENTRY_BYTES
        {
            remove_dedup_entry(&index, &hash);
            return None;
        }
        let name = std::str::from_utf8(&bytes).ok()?;
        let name = name.trim_end_matches('\n');
        let plain =
            !name.is_empty() && name != "." && name != ".." && !name.contains('/') && !name.contains('\0');
        let stored = folder.join(name);
        let valid = plain
            && std::fs::symlink_metadata(&stored).is_ok_and(|meta| meta.is_file() && meta.len() == size)
            && file_sha256(&stored).as_deref() == Some(hash.as_str());
        if !valid {
            remove_dedup_entry(&index, &hash);
            return None;
        }
        Some(stored)
    })
    .await
    .ok()
    .flatten()
}

/// Records `stored` as the file for `hash` (best effort: a failed record only costs a later
/// re-send its bytes). The hash is the phone's claim; a lookup re-verifies it before use.
fn dedup_record(index: &Path, hash: &str, stored: &Path) {
    use std::io::Write;
    use std::os::fd::{AsRawFd, FromRawFd};

    let Some(name) = stored.file_name().and_then(|n| n.to_str()) else { return };
    let Some(index) = open_dedup_index(index, true) else { return };
    let temp_name = format!(".{hash}.{}.tmp", uuid::Uuid::new_v4());
    let Some(temp_name_c) = dedup_name(&temp_name) else { return };
    let fd = unsafe {
        libc::openat(
            index.as_raw_fd(),
            temp_name_c.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW,
            0o600,
        )
    };
    if fd == -1 {
        return;
    }
    // SAFETY: `fd` is the owned descriptor returned by openat.
    let mut temp = unsafe { std::fs::File::from_raw_fd(fd) };
    let written = temp.write_all(name.as_bytes());
    let hash_name = dedup_name(hash);
    let renamed = if written.is_ok() {
        hash_name.is_some_and(|hash_name| unsafe {
            libc::renameat(index.as_raw_fd(), temp_name_c.as_ptr(), index.as_raw_fd(), hash_name.as_ptr())
                == 0
        })
    } else {
        false
    };
    drop(temp);
    if !renamed {
        let _ = unsafe { libc::unlinkat(index.as_raw_fd(), temp_name_c.as_ptr(), 0) };
    }
}

// A phone's local channel close can finish just before hostd releases the file.
// Wake immediate retries when a writer finishes, including writers on another link.
static UPLOAD_UNLOCKED: std::sync::LazyLock<tokio::sync::watch::Sender<()>> =
    std::sync::LazyLock::new(|| tokio::sync::watch::channel(()).0);

struct UploadLockRelease;

impl Drop for UploadLockRelease {
    fn drop(&mut self) {
        UPLOAD_UNLOCKED.send_replace(());
    }
}

async fn open_upload_part(part: &Path) -> Result<std::fs::File, Refusal> {
    let open = async {
        let mut unlocked = UPLOAD_UNLOCKED.subscribe();
        loop {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(part)
                .map_err(|e| Refusal::new("io", e.to_string()))?;
            match file.try_lock() {
                Ok(()) => return Ok(file),
                Err(std::fs::TryLockError::WouldBlock) => drop(file),
                Err(std::fs::TryLockError::Error(e)) => return Err(Refusal::new("io", e.to_string())),
            }
            let _ = unlocked.changed().await;
        }
    };
    timeout(Duration::from_secs(2), open)
        .await
        .map_err(|_| Refusal::new("busy", "another channel is writing this upload"))?
}

async fn send_upload_ack(sender: &ChannelSender, received: u64) {
    let _ = sender.send(Bytes::from(format!("{{\"ack\":{received}}}\n"))).await;
}

struct UploadPartsDirStream(*mut libc::DIR);

impl Drop for UploadPartsDirStream {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: fdopendir transfers ownership of this descriptor to the
            // DIR stream, which remains valid until this guard is dropped.
            unsafe { libc::closedir(self.0) };
        }
    }
}

fn cleanup_stale_upload_parts(folder: &Path) {
    let Ok(directory) = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(folder)
    else {
        return;
    };
    cleanup_stale_upload_parts_fd(&directory);
}

fn cleanup_stale_upload_parts_fd(directory: &std::fs::File) {
    use std::ffi::CStr;
    use std::os::fd::{AsRawFd, FromRawFd};

    // Keep the verified directory open for the complete scan and cleanup.  A
    // pathname read followed by remove_file(path) can be redirected by a
    // concurrent rename or symlink replacement, including outside the upload
    // folder.  Enumerate through a duplicate descriptor and unlink relative
    // to the original descriptor instead.
    let directory_fd = directory.as_raw_fd();
    let duplicate = unsafe { libc::dup(directory_fd) };
    if duplicate == -1 {
        return;
    }
    let stream = UploadPartsDirStream(unsafe { libc::fdopendir(duplicate) });
    if stream.0.is_null() {
        unsafe { libc::close(duplicate) };
        return;
    }
    let stale = |meta: &std::fs::Metadata| {
        meta.is_file()
            && meta
                .modified()
                .ok()
                .and_then(|t| t.elapsed().ok())
                .is_some_and(|age| age > UPLOAD_PART_MAX_AGE)
    };
    unsafe {
        // Process each name while the descriptor remains open instead of
        // retaining an unbounded list for large staging directories.
        loop {
            let entry = libc::readdir(stream.0);
            if entry.is_null() {
                break;
            }
            let bytes = CStr::from_ptr((*entry).d_name.as_ptr()).to_bytes();
            if bytes == b"."
                || bytes == b".."
                || !bytes
                    .strip_prefix(b".")
                    .is_some_and(|rest| rest.ends_with(b".part") || rest.ends_with(b".done"))
            {
                continue;
            }
            let Ok(name) = std::ffi::CString::new(bytes) else { continue };
            let fd = libc::openat(
                directory_fd,
                name.as_ptr(),
                libc::O_WRONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            );
            if fd == -1 {
                continue;
            }
            // SAFETY: `fd` is the owned descriptor returned by openat.
            let file = std::fs::File::from_raw_fd(fd);
            // Recheck under the writer's lock. A retry may have reopened the part during the scan.
            if file.try_lock().is_ok() && file.metadata().is_ok_and(|meta| stale(&meta) && meta.nlink() == 1)
            {
                let _ = libc::unlinkat(directory_fd, name.as_ptr(), 0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_completion_recovers_interrupted_publication_and_checks_bytes() {
        let folder = tempfile::tempdir().unwrap();
        let parts = upload_parts_dir(folder.path(), "phone").unwrap();
        let part = parts.join(".recovery.part");
        let receipt = parts.join(".recovery.done");
        std::fs::write(folder.path().join("a.txt"), "old").unwrap();
        std::fs::write(&part, "new").unwrap();
        // Simulate process loss after the second hard link and during receipt
        // serialization. The partial temporary receipt is never authoritative.
        let published = link_upload(folder.path(), "a.txt", &part).unwrap();
        std::fs::write(parts.join(".recovery.interrupted.part"), "{broken").unwrap();
        let hash = format!("{:x}", Sha256::digest(b"new"));
        let recovered =
            publish_resumable_upload(folder.path(), "a.txt", &part, &receipt, 3, Some(&hash)).unwrap();
        assert_eq!(recovered, published);
        assert!(!folder.path().join("a 3.txt").exists());
        assert!(!part.exists());
        assert_eq!(
            completed_upload(&receipt, folder.path(), "a.txt", 3, Some(&hash)).unwrap(),
            Some(published.clone())
        );
        let wrong_hash = "0".repeat(64);
        assert!(completed_upload(&receipt, folder.path(), "a.txt", 3, Some(&wrong_hash)).is_err());
        // Same inode, same size is insufficient proof of completion.
        std::fs::write(&published, "bad").unwrap();
        assert!(completed_upload(&receipt, folder.path(), "a.txt", 3, Some(&hash)).is_err());
    }

    #[test]
    fn upload_completion_refuses_legacy_hashless_and_partial_receipts() {
        let folder = tempfile::tempdir().unwrap();
        let parts = upload_parts_dir(folder.path(), "phone").unwrap();
        let receipt = parts.join(".legacy.done");
        let published = folder.path().join("a.txt");
        std::fs::write(&published, b"new").unwrap();
        let meta = std::fs::metadata(&published).unwrap();
        let legacy = serde_json::json!({
            "name": "a.txt", "size": 3, "file": "a.txt",
            "device": meta.dev(), "inode": meta.ino()
        });
        let hash = format!("{:x}", Sha256::digest(b"new"));
        // Development receipts without a recorded digest cannot establish the
        // original content. Never silently upgrade them from current bytes.
        for bytes in [serde_json::to_vec(&legacy).unwrap(), b"{broken".to_vec()] {
            std::fs::write(&receipt, &bytes).unwrap();
            for supplied in [None, Some(hash.as_str())] {
                assert!(completed_upload(&receipt, folder.path(), "a.txt", 3, supplied).is_err());
            }
            assert_eq!(std::fs::read(&receipt).unwrap(), bytes);
            assert_eq!(std::fs::read(&published).unwrap(), b"new");
        }
    }

    #[test]
    fn upload_parts_stay_inside_authorized_folder_and_are_private() {
        use std::os::unix::fs::PermissionsExt;
        let workspace = tempfile::tempdir().unwrap();
        let folder = workspace.path().join("project");
        std::fs::create_dir(&folder).unwrap();
        // A publish folder resolving to the workspace root used to stage in
        // its parent. The caller may pass precisely that authorized root.
        let parts = upload_parts_dir(&folder, "phone-a").unwrap();
        assert_eq!(parts.parent(), Some(std::fs::canonicalize(&folder).unwrap().as_path()));
        assert_eq!(std::fs::metadata(&parts).unwrap().permissions().mode() & 0o777, 0o700);
        let other = upload_parts_dir(&folder, "phone-b").unwrap();
        assert_ne!(parts, other);
        // Existing permissive staging directories are made private again.
        std::fs::set_permissions(&parts, std::fs::Permissions::from_mode(0o755)).unwrap();
        upload_parts_dir(&folder, "phone-a").unwrap();
        assert_eq!(std::fs::metadata(parts).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn upload_parts_refuse_symlink_aliases_between_devices() {
        let workspace = tempfile::tempdir().unwrap();
        let first = upload_parts_dir(workspace.path(), "phone-a").unwrap();
        let alias = workspace.path().join(format!(".parts-{:x}", Sha256::digest(b"phone-b")));
        std::os::unix::fs::symlink(&first, &alias).unwrap();
        assert!(upload_parts_dir(workspace.path(), "phone-b").is_err());
    }

    #[test]
    fn stale_cleanup_does_not_follow_file_symlinks() {
        let workspace = tempfile::tempdir().unwrap();
        let folder = workspace.path().join("parts");
        let outside = workspace.path().join("outside.part");
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(&outside, b"keep").unwrap();
        std::os::unix::fs::symlink(&outside, folder.join(".stale.part")).unwrap();

        cleanup_stale_upload_parts(&folder);

        assert!(outside.exists());
        assert!(folder.join(".stale.part").exists());
    }

    #[test]
    fn stale_cleanup_keeps_descriptor_when_folder_path_is_replaced() {
        use std::os::unix::fs::symlink;

        let workspace = tempfile::tempdir().unwrap();
        let folder = workspace.path().join("parts");
        let moved = workspace.path().join("parts-moved");
        let outside = workspace.path().join("outside");
        std::fs::create_dir(&folder).unwrap();
        std::fs::create_dir(&outside).unwrap();
        let stale = folder.join(".old.part");
        let victim = outside.join(".victim.part");
        std::fs::write(&stale, b"old").unwrap();
        std::fs::write(&victim, b"keep").unwrap();
        let old = std::time::SystemTime::now() - UPLOAD_PART_MAX_AGE - Duration::from_secs(1);
        std::fs::File::open(&stale).unwrap().set_modified(old).unwrap();
        std::fs::File::open(&victim).unwrap().set_modified(old).unwrap();

        let directory = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&folder)
            .unwrap();
        std::fs::rename(&folder, &moved).unwrap();
        symlink(&outside, &folder).unwrap();

        cleanup_stale_upload_parts_fd(&directory);

        assert!(!moved.join(".old.part").exists());
        assert!(victim.exists(), "cleanup must not follow a replaced folder path");
    }

    /// The query is the bytes hostd always sent, its capability names now from the registry.
    #[test]
    fn surface_query_is_unchanged() {
        assert_eq!(
            surface_query(),
            "{\"cmd\":\"set-client-info\",\"id\":\"cmux-mobile-surface-hello\",\"name\":\"cmux-mobile-host\",\"kind\":\"cli\",\"capabilities\":[\"conversation-tabs-v1\",\"page-tabs-v1\"]}\n{\"cmd\":\"list-workspaces\",\"id\":\"cmux-mobile-surface\"}\n"
        );
    }

    /// A reply in one frame past tungstenite's default 16 MiB frame limit reads whole: an older
    /// acpmux sends its whole watch list so (24.8 MB on one Mac, 2026-11-06), and the push
    /// watcher dropped it and asked again about every minute.
    #[tokio::test]
    async fn the_acpmux_socket_takes_a_frame_past_16_mib() {
        use futures_util::{SinkExt as _, StreamExt as _};
        use tokio_tungstenite::tungstenite::Message as WsMessage;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}/", listener.local_addr().unwrap());
        let reply = "x".repeat(20 << 20);
        let sent = reply.clone();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let limits = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
                .max_message_size(Some(ACPMUX_MAX_MESSAGE_BYTES))
                .max_frame_size(Some(ACPMUX_MAX_MESSAGE_BYTES));
            let mut socket = tokio_tungstenite::accept_async_with_config(stream, Some(limits)).await.unwrap();
            socket.send(WsMessage::Text(sent.into())).await.unwrap();
            // Held open until the client has read the frame.
            let _ = socket.next().await;
        });
        let target = AcpmuxTarget::Fixed { url, token: None };
        let mut socket = connect_acpmux_as(&target, None).await.unwrap();
        let read = socket.next().await.expect("a frame").expect("read whole, not refused for its size");
        assert_eq!(read.into_text().unwrap().len(), reply.len());
        drop(socket);
        server.await.unwrap();
    }

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
            viewport_sync: None,
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
            viewport_sync: None,
        };
        assert_eq!(
            capabilities(&config),
            [
                "removal-v1",
                "file-preview-v1",
                "localhost-forward-v1",
                "cloud-directory-v1",
                "cloud-acpmux-v1",
                "needs-you-v1",
                "appearance-v1",
                "pair-requests-v1",
                "phone-frames-v1",
                "tab-snapshots-v1",
                "phone-page-v1",
                "mailbox-send-v1",
                "bundle-v1"
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
                "needs-you-v1",
                "appearance-v1",
                "pair-requests-v1",
                "phone-frames-v1",
                "tab-snapshots-v1",
                "phone-page-v1",
                "mailbox-send-v1",
                "bundle-v1",
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
                {"machine_id": "m1", "team_id": "t", "name": "m1 box", "status": "running", "ran": true, "linked": true},
                {"machine_id": "m2", "team_id": "t", "name": "m2 box", "status": "paused", "ran": true, "linked": false},
                {"machine_id": "m5", "team_id": "t", "name": "m5 box", "status": "unknown", "ran": false, "linked": true},
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
            viewport_sync: None,
        };
        assert!(!capabilities(&config).contains(&CLOUD_DESKTOP));
        config.surface = crate::surface::SurfaceConfig::new(Some(launcher), 1);
        assert!(capabilities(&config).ends_with(&[SURFACE_STREAM, CLOUD_DESKTOP]));
        // A Mac whose app cannot stream simulators still streams Cloud desktops, and never says
        // `surface-stream-v1` (its phone would wait on a simulator that never opens).
        config.surface = config.surface.clone().without_simulators();
        assert!(!capabilities(&config).contains(&SURFACE_STREAM));
        assert!(capabilities(&config).ends_with(&[CLOUD_DESKTOP]));
        assert!(!capabilities(&config).contains(&MAC_DISPLAY));
        // The app that also captures this Mac's displays says so (`CMUX_MOBILE_MAC_DISPLAY=1`).
        config.surface = config.surface.clone().with_mac_display();
        assert!(capabilities(&config).ends_with(&[CLOUD_DESKTOP, MAC_DISPLAY]));
        // No source at all: no display either.
        config.surface = crate::surface::SurfaceConfig::default().with_mac_display();
        assert!(!capabilities(&config).contains(&MAC_DISPLAY));
    }

    /// Everything `version` can list is a host name in the registry, and every host name there
    /// is one `version` can list.
    #[test]
    fn version_capabilities_are_the_registry_host_names() {
        let listed: Vec<&str> = CAPABILITIES
            .iter()
            .copied()
            .chain([
                BROWSER_STREAM,
                BROWSER_VIDEO_TRACK,
                SURFACE_STREAM,
                CLOUD_DESKTOP,
                MAC_DISPLAY,
                crate::try_pr::CAPABILITY,
                names::SITE_DATA_HANDOFF,
            ])
            .collect();
        let host: Vec<&str> =
            names::ALL.iter().filter(|c| c.side == names::Side::Host).map(|c| c.name).collect();
        assert_eq!(listed, host);
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

#[cfg(test)]
mod session_exposure_queue_tests {
    use super::*;

    const CHAT: &str = "00000000-0000-7000-8000-000000000001";

    #[test]
    fn queued_daemon_command_and_reply_use_current_policy() {
        let (tx, rx) = tokio::sync::watch::channel(crate::control::SessionExposure::default());
        let request = serde_json::json!({"id":"queued","cmd":"new-conversation-tab",
            "agent_session":{"session":CHAT}})
        .to_string()
        .into_bytes();
        let reply = serde_json::json!({"id":"list","data":{"tabs":[
            {"id":"hidden","agent_session":{"session":CHAT}}, {"id":"terminal"}
        ]}})
        .to_string()
        .into_bytes();
        assert!(daemon_exposure_refusal(&request, Some(&rx)).is_none());
        assert!(
            String::from_utf8(exposed_daemon_line(reply.clone(), Some(&rx)).unwrap())
                .unwrap()
                .contains("hidden")
        );
        // The side worker/reply queue was waiting while the person revoked this chat.
        tx.send_replace(crate::control::SessionExposure {
            configured: true,
            blocked: [CHAT.to_owned()].into_iter().collect(),
            ..crate::control::SessionExposure::default()
        });
        let refused: Value =
            serde_json::from_slice(&daemon_exposure_refusal(&request, Some(&rx)).unwrap()).unwrap();
        assert_eq!(refused["id"], "queued");
        let filtered: Value =
            serde_json::from_slice(&exposed_daemon_line(reply, Some(&rx)).unwrap()).unwrap();
        assert_eq!(filtered.pointer("/data/tabs").unwrap().as_array().unwrap().len(), 1);
        assert_eq!(filtered["data"]["tabs"][0]["id"], "terminal");
    }
}

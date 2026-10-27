//! The host loop: register, hold the signaling socket, admit and answer
//! dials, and serve each link's channels.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use cmux_mobile_link::api::{ApiClient, DeviceRegistration, IceCache, IceServer};
use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::signaling::{SignalEnvelope, SignalPayload};
use cmux_mobile_link::{DialOptions, LinkConfig, SignalingClient, Timeline, TransportKind};

use crate::auth::{Tokens, claims};
use crate::config::{HostConfig, ServiceConfig};
use crate::control::{self, Event};
use crate::services::{self, Peer};
use crate::tasks::{Ended, TaskScope, WorkerFailed, Workers};

/// What a phone's task serves. A task that panics ends that phone only: its
/// link closes as the task unwinds, and the other phones keep working.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PhoneTask {
    /// A link from `answer_session`.
    Link { session_id: String },
    /// A WebRTC media session beside a link (`media_session.rs`).
    Media { session_id: String },
    /// One `mailbox` frame being applied and acknowledged.
    Mailbox,
}

/// The phones' tasks. They outlive one signaling socket (a WireGuard link
/// keeps running across a reconnect), so `run` owns them for the process.
pub type Phones = TaskScope<PhoneTask>;

/// Logs how a phone's task ended; a panic is that phone's failure.
fn phone_task_ended(ended: Ended<PhoneTask>) {
    match ended {
        Ended::Finished(_) => {}
        Ended::Panicked(PhoneTask::Link { session_id }, message) => {
            tracing::error!(session_id, message, "a phone's link task failed; that link is closed");
            control::emit(&Event::PhoneDown { session_id, reason: "hostd_error".into() });
        }
        Ended::Panicked(task, message) => tracing::error!(?task, message, "a phone's task failed"),
        Ended::Cancelled => tracing::debug!("a phone's task was cancelled by the runtime"),
    }
}

/// How the host answers dials on one signaling connection.
#[derive(Clone)]
pub struct AnswerContext {
    /// Only phones of this Stack user are admitted.
    pub owner_user_id: String,
    pub services: Arc<ServiceConfig>,
    /// ICE servers; `None` fetches `GET /v1/ice` per session.
    pub ice: IceSource,
    pub include_loopback: bool,
    pub exclude_cgnat: bool,
    /// Supervised: sealed replies the backend holds for this Mac (`mailbox.rs`).
    pub mailbox: Option<Arc<crate::mailbox::Mailbox>>,
}

#[derive(Clone)]
pub enum IceSource {
    Fixed(Vec<IceServer>),
    /// `GET /v1/ice` with a current access token (the signaling socket
    /// outlives any one token), cached while the credentials have half
    /// their lifetime left and refreshed ahead of the next dial, so an
    /// answer never waits on an HTTP round trip.
    Api {
        base_url: String,
        tokens: Arc<Tokens>,
        cache: Arc<IceCache>,
    },
}

/// A signaling socket up at least this long reconnects after `QUICK_RECONNECT`.
const LONG_LIVED: Duration = Duration::from_secs(20);
const QUICK_RECONNECT: Duration = Duration::from_millis(150);

/// How long an answer waits for `GET /v1/ice` when nothing is cached.
const ICE_BUDGET: Duration = Duration::from_secs(5);

impl IceSource {
    pub fn api(base_url: String, tokens: Arc<Tokens>) -> Self {
        Self::Api { base_url, tokens, cache: Arc::new(IceCache::new()) }
    }

    /// The servers and whether they came from the cache.
    pub(crate) async fn servers(&self) -> (Vec<IceServer>, bool) {
        match self {
            Self::Fixed(servers) => (servers.clone(), true),
            Self::Api { base_url, tokens, cache } => {
                if let Some(servers) = cache.fresh() {
                    return (servers, true);
                }
                let token = match tokens.access_token().await {
                    Ok(token) => token,
                    Err(error) => {
                        tracing::warn!("no access token for GET /v1/ice ({error:#}); host candidates only");
                        return (Vec::new(), false);
                    }
                };
                cache.get(&ApiClient::new(base_url, &token), ICE_BUDGET).await
            }
        }
    }

    /// Measurement support (`CMUX_MOBILE_BASELINE`): fetch per answer, as before the cache.
    async fn servers_uncached(&self) -> (Vec<IceServer>, bool) {
        if let Self::Api { cache, .. } = self {
            cache.clear();
        }
        self.servers().await
    }

    /// Keep the cache filled while the host runs: fetch now, then again
    /// whenever it is about to go stale.
    fn keep_fresh(&self) -> Option<tokio::task::JoinHandle<()>> {
        let Self::Api { .. } = self else { return None };
        let source = self.clone();
        Some(tokio::spawn(async move {
            loop {
                let (servers, _) = source.servers().await;
                let wait = if servers.is_empty() { Duration::from_secs(30) } else { Duration::from_secs(60) };
                tokio::time::sleep(wait).await;
            }
        }))
    }
}

/// When a phone first registered (`GET /v1/me/devices` `createdAt`), for the
/// pairing prompt. Every phone that may dial is the Mac owner's own device.
fn registration_lookup(base_url: String, tokens: Arc<Tokens>) -> crate::pairing::RegistrationLookup {
    Arc::new(move |phone: String| {
        let (base_url, tokens) = (base_url.clone(), Arc::clone(&tokens));
        Box::pin(async move {
            let token = tokens.access_token().await.ok()?;
            let devices = ApiClient::new(&base_url, &token).my_devices().await.ok()?;
            devices
                .into_iter()
                .find(|d| d.device_id.eq_ignore_ascii_case(&phone) && d.kind != "mac")
                .and_then(|d| d.created_at)
                .and_then(|at| crate::pairing::epoch_millis(&at))
        })
    })
}

/// Run until the process is stopped, reconnecting with backoff. Returns `Ok` only when
/// the owner removed this Mac (`removed`): registering again would undo that. `workers`
/// holds the process workers main started (control input, SIGTERM); `run` adds its own,
/// and the first one that fails ends `run` with that failure (hostd then exits with
/// `tasks::EXIT_WORKER_FAILED` and its supervisor starts it again).
pub async fn run(config: HostConfig, mut workers: Workers) -> Result<(), WorkerFailed> {
    let tokens = Arc::new(Tokens::new(config.tokens.clone()));
    let mut services = config.services.clone();
    if let Some(pairing) = services.pairing.as_mut() {
        pairing.registration = Some(registration_lookup(config.base_url.clone(), Arc::clone(&tokens)));
    }
    let services = Arc::new(services);
    // One ICE cache for the life of the process (reconnects keep it).
    let ice = IceSource::api(config.base_url.clone(), Arc::clone(&tokens));
    if crate::notify::enabled() {
        // Paired phones that gave a push key get sealed notifications (sealed_notify.rs).
        let sealer = services.pairing.as_ref().map(|pairing| {
            Arc::new(crate::sealed_notify::Sealer {
                mac: pairing.mac_device_id.clone(),
                identity: pairing.identity.clone(),
                trust: pairing.trust.clone(),
                push_keys: Arc::clone(&pairing.push_keys),
                acpmux: services.acpmux.clone(),
            })
        });
        workers.spawn(
            "push notifications",
            crate::notify::run(
                config.base_url.clone(),
                config.device_id.clone(),
                Arc::clone(&tokens),
                config.services.acpmux.clone(),
                Some(config.services.daemon_socket()),
                sealer,
            ),
        );
    }
    let mailbox = mailbox_for(&services).map(|(mailbox, turns)| {
        workers.spawn("mailbox turns", turns);
        mailbox
    });
    // Phones keep their WireGuard sessions when the Mac changes networks.
    workers.spawn("network watcher", crate::netwatch::run());
    // Test-only signal hooks, never in a normal install: only when the state
    // folder holds a `test-signals` file a rig created (PR #22555 review).
    if crate::config::default_state_dir().join("test-signals").exists() {
        tracing::warn!("test signals on (SIGUSR1 media black hole, SIGUSR2 media kill)");
        workers.spawn("test signals", crate::media_session::test_signals());
    }
    let mut phones = Phones::default();
    let mut backoff = Duration::from_secs(1);
    loop {
        control::emit(&Event::Connecting);
        let started = std::time::Instant::now();
        let attempt = tokio::select! {
            failed = workers.failed() => return Err(failed),
            attempt = connect_once(&config, &tokens, &services, &ice, &mailbox, &mut phones) => attempt,
        };
        let reason = match attempt {
            Ok(reason) if removed(&reason) => {
                // Registering again would undo the owner's removal: stop for good.
                tracing::warn!(reason, "this Mac was removed from the account's devices; stopping");
                control::emit(&Event::Removed);
                return Ok(());
            }
            Ok(reason) => {
                tracing::warn!(reason, "signaling ended; reconnecting");
                // A socket that was up for a while and then reset (every Worker
                // deploy resets all sockets) comes back at once, so a phone
                // dialing now finds the Mac; quick repeated failures back off.
                backoff =
                    if started.elapsed() > LONG_LIVED { QUICK_RECONNECT } else { Duration::from_secs(1) };
                reason
            }
            Err(error) => {
                tracing::warn!("connection attempt failed: {error:#}");
                // Only a refusal of the token itself marks it refused; a network error or a
                // server error keeps it (the supervising app would otherwise refresh on every retry).
                if unauthorized(&error) {
                    tokens.invalidate().await;
                }
                backoff = (backoff * 2).min(Duration::from_secs(60));
                format!("{error:#}")
            }
        };
        control::emit(&Event::Waiting { reason, retry_in_seconds: backoff.as_secs() });
        let retry = tokio::time::sleep(backoff);
        tokio::pin!(retry);
        loop {
            tokio::select! {
                failed = workers.failed() => return Err(failed),
                ended = phones.ended() => phone_task_ended(ended),
                () = &mut retry => break,
            }
        }
    }
}

async fn connect_once(
    config: &HostConfig,
    tokens: &Arc<Tokens>,
    services: &Arc<ServiceConfig>,
    ice: &IceSource,
    mailbox: &Option<Arc<crate::mailbox::Mailbox>>,
    phones: &mut Phones,
) -> Result<String> {
    let token = tokens.access_token().await.context("access token")?;
    let owner = config
        .owner_user_id
        .clone()
        .or_else(|| claims(&token).sub)
        .context("the access token has no sub; set CMUX_MOBILE_OWNER_USER_ID")?;
    let api = ApiClient::new(&config.base_url, &token);
    let (machine_id, sibling_device_ids) = config.machine(&owner);
    let device = api
        .register_device(&DeviceRegistration {
            device_id: config.device_id.clone(),
            kind: "mac".into(),
            name: config.device_name.clone(),
            team_id: config.team_id.clone(),
            wg_public_key: None,
            machine_id,
            sibling_device_ids,
        })
        .await
        .context("POST /v1/devices")?;
    tracing::info!(device = %device, "registered");
    let signaling = SignalingClient::connect(&config.base_url, &token, &config.team_id, &config.device_id)
        .await
        .context("signaling connect")?;
    tracing::info!(device_id = config.device_id, "signaling connected");
    // Sessions of the previous socket (WireGuard tunnels outlive it) send
    // their `bye` on this one now.
    let moved = dial::wireguard::rehome(&signaling);
    if moved > 0 {
        tracing::info!(moved, "WireGuard sessions moved to the new signaling socket");
    }
    control::emit(&Event::Online { device_id: config.device_id.clone(), team_id: config.team_id.clone() });
    let context = AnswerContext {
        owner_user_id: owner,
        services: Arc::clone(services),
        ice: ice.clone(),
        include_loopback: config.include_loopback,
        exclude_cgnat: config.exclude_cgnat,
        mailbox: mailbox.clone(),
    };
    let refresher = if std::env::var_os("CMUX_MOBILE_BASELINE").is_some() { None } else { ice.keep_fresh() };
    let reason = serve_signaling_with(signaling, context, phones).await;
    if let Some(task) = refresher {
        task.abort();
    }
    Ok(reason)
}

/// hostd's exit status after the owner removed this Mac (`removed`): a supervisor must not restart it.
pub const EXIT_REMOVED: i32 = 78;

/// Whether the signaling socket closed because the owner removed this device
/// (`DELETE /v1/devices/:id` closes it with 4002 `removed`, PROTOCOL.md).
pub fn removed(reason: &str) -> bool {
    reason.starts_with("signaling closed by server: 4002 ")
}

/// Whether `error` is the backend refusing the access token (HTTP 401 from the API or
/// the signaling upgrade).
pub fn unauthorized(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        if let Some(cmux_mobile_link::api::ApiError::Status { status, .. }) =
            cause.downcast_ref::<cmux_mobile_link::api::ApiError>()
        {
            return *status == 401;
        }
        if let Some(cmux_mobile_link::signaling::SignalingError::Connect(message)) =
            cause.downcast_ref::<cmux_mobile_link::signaling::SignalingError>()
        {
            return message.contains("401");
        }
        false
    })
}

/// The mailbox of a supervised hostd: its pairing's keys and trust, the
/// services a link reaches, and the replies already spent (on disk); with the
/// worker that holds the acpmux connections of prompts whose turn still runs.
fn mailbox_for(
    services: &ServiceConfig,
) -> Option<(Arc<crate::mailbox::Mailbox>, impl std::future::Future<Output = ()> + Send + 'static)> {
    let pairing = services.pairing.as_ref()?;
    let daemon_socket = services
        .default_socket
        .clone()
        .unwrap_or_else(|| services.tui_socket_dir.join(format!("{}.sock", services.default_session)));
    let (turns, held_turns) = crate::mailbox_apply::TurnHolder::new();
    let mailbox = Arc::new(crate::mailbox::Mailbox {
        mac: pairing.mac_device_id.clone(),
        trust: pairing.trust.clone(),
        identity: pairing.identity.clone(),
        spent: Arc::clone(&pairing.spent_replies),
        key_wait: crate::pairing::TRUST_WAIT,
        applier: Arc::new(crate::mailbox_apply::LiveApplier {
            acpmux: services.acpmux.clone(),
            daemon_socket,
            chief_socket: services.chief_socket.clone(),
            turns,
        }),
    });
    Some((mailbox, held_turns))
}

/// How long hostd waits before it tries an item it could not settle again.
const MAILBOX_RETRY: std::time::Duration = std::time::Duration::from_secs(30);

/// Checks and applies a `mailbox` frame in the background, then acks every
/// settled item (signed). An item it could not settle yet (the app has not
/// sent its keys, a service is out of reach) is not acknowledged: it stays
/// queued at the backend and is tried again here while the socket lives.
/// Without pairing (unsupervised) nothing is applied. The work is a task of `phones`.
pub fn answer_mailbox(
    signaling: &SignalingClient,
    mailbox: Option<Arc<crate::mailbox::Mailbox>>,
    items: Vec<cmux_mobile_link::signaling::MailboxItem>,
    phones: &mut Phones,
) {
    let signaling = signaling.clone();
    phones.spawn(PhoneTask::Mailbox, async move {
        let Some(mailbox) = mailbox else {
            let results = items
                .into_iter()
                .take(crate::mailbox::MAX_ITEMS)
                .map(|item| cmux_mobile_link::signaling::MailboxResult {
                    id: item.id,
                    applied: false,
                    reason: Some("not_paired".into()),
                    sig: None,
                })
                .collect();
            if let Err(error) = signaling.send_mailbox_ack(results) {
                tracing::warn!(%error, "mailbox ack not sent");
            }
            return;
        };
        let mut items = items;
        while !items.is_empty() && signaling.closed_reason().is_none() {
            let handled = mailbox.handle(items, crate::mailbox::now()).await;
            if !handled.results.is_empty()
                && let Err(error) = signaling.send_mailbox_ack(handled.results)
            {
                tracing::warn!(%error, "mailbox ack not sent");
                return;
            }
            items = handled.later;
            if !items.is_empty() {
                tokio::time::sleep(MAILBOX_RETRY).await;
            }
        }
    });
}

/// Answer every admitted dial on `signaling` until it closes; returns the
/// close reason. The phones' links end with it (`run` keeps them across
/// reconnects through [`serve_signaling_with`]).
pub async fn serve_signaling(signaling: SignalingClient, context: AnswerContext) -> String {
    let mut phones = Phones::default();
    serve_signaling_with(signaling, context, &mut phones).await
}

/// [`serve_signaling`] with the phones' tasks in `phones`, which outlives the socket.
pub async fn serve_signaling_with(
    signaling: SignalingClient,
    context: AnswerContext,
    phones: &mut Phones,
) -> String {
    let mut events = signaling.events();
    loop {
        let session = tokio::select! {
            session = signaling.next_session() => match session {
                Some(session) => session,
                None => return signaling.closed_reason().unwrap_or_else(|| "signaling closed".into()),
            },
            // A queue, not an event: frames sent right after `hello` wait for this loop.
            Some(items) = signaling.next_mailbox() => {
                answer_mailbox(&signaling, context.mailbox.clone(), items, phones);
                continue;
            }
            ended = phones.ended() => {
                phone_task_ended(ended);
                continue;
            }
            event = events.recv() => match event {
                Ok(cmux_mobile_link::signaling::SignalingEvent::Disconnected(reason)) => return reason,
                Ok(cmux_mobile_link::signaling::SignalingEvent::Error { code, message, session_id }) => {
                    tracing::debug!(code, message, ?session_id, "backend error");
                    continue;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => return "signaling closed".into(),
            },
        };
        let envelope = session.first;
        let media_for = dial::media_session_for(&envelope.payload).map(str::to_owned);
        let kind = TransportKind::for_first_signal(&envelope.payload);
        if kind.is_none() && media_for.is_none() {
            continue;
        }
        if !admitted(&envelope, &context.owner_user_id) {
            tracing::warn!(from = envelope.from, user = ?envelope.from_user_id, "refusing a dial from another user");
            signaling.unsubscribe(&envelope.session_id);
            let _ = signaling.send_signal(
                &envelope.from,
                &envelope.session_id,
                SignalPayload::Bye { reason: "not_admitted".into() },
            );
            continue;
        }
        let session_events = SessionEvents {
            session: session.events,
            backend: signaling.events(),
            session_id: envelope.session_id.clone(),
        };
        match (kind, media_for) {
            (Some(kind), _) => {
                let session_id = envelope.session_id.clone();
                phones.spawn(
                    PhoneTask::Link { session_id },
                    answer_session(signaling.clone(), envelope, session_events, kind, context.clone()),
                );
            }
            (None, Some(link)) => {
                let session_id = envelope.session_id.clone();
                phones.spawn(
                    PhoneTask::Media { session_id },
                    crate::media_session::answer(
                        signaling.clone(),
                        envelope,
                        session_events,
                        link,
                        context.clone(),
                    ),
                );
            }
            (None, None) => {}
        }
    }
}

/// Measurement support: drop this many of every 1000 outgoing video RTP
/// packets (below the NACK responder, as a lossy path would), from
/// `CMUX_MOBILE_VIDEO_DROP_PERMILLE` or the file `$CMUX_MOBILE_STATE_DIR/video-drop-permille`
/// (the app starts hostd with its own environment; the file applies to the
/// next link without a restart).
pub(crate) fn video_drop_permille() -> u32 {
    measurement_knob("CMUX_MOBILE_VIDEO_DROP_PERMILLE", "video-drop-permille").unwrap_or(0).min(500) as u32
}

/// Measurement support (WireGuard lane only): a bottleneck for outgoing
/// video RTP in kbit/s, from `CMUX_MOBILE_VIDEO_CAP_KBPS` or the file
/// `$CMUX_MOBILE_STATE_DIR/video-cap-kbps`. 0 or absent: none.
fn video_cap_bps() -> u64 {
    measurement_knob("CMUX_MOBILE_VIDEO_CAP_KBPS", "video-cap-kbps").unwrap_or(0).min(1_000_000) * 1000
}

/// A number from the environment, else from a file in `$CMUX_MOBILE_STATE_DIR`.
pub(crate) fn measurement_knob(variable: &str, file: &str) -> Option<u64> {
    let from_file = std::env::var_os("CMUX_MOBILE_STATE_DIR")
        .and_then(|dir| std::fs::read_to_string(std::path::Path::new(&dir).join(file)).ok());
    std::env::var(variable).ok().or(from_file).and_then(|v| v.trim().parse().ok())
}

/// v1 admission (PROTOCOL.md): the dialing phone belongs to the Mac's own
/// Stack user, as stamped by the backend in `fromUserId`. Missing means deny.
pub fn admitted(envelope: &SignalEnvelope, owner_user_id: &str) -> bool {
    envelope.from_user_id.as_deref() == Some(owner_user_id)
}

async fn answer_session(
    signaling: SignalingClient,
    first: SignalEnvelope,
    events: SessionEvents,
    kind: TransportKind,
    context: AnswerContext,
) {
    let mut peer = Peer { device_id: first.from.clone(), session_id: first.session_id.clone(), video: None };
    let session_id = first.session_id.clone();
    let timeline = Timeline::new();
    timeline.mark("offer_received");
    let baseline = std::env::var_os("CMUX_MOBILE_BASELINE").is_some();
    let (ice_servers, cached) =
        if baseline { context.ice.servers_uncached().await } else { context.ice.servers().await };
    timeline.mark(if cached { "ice_servers_cached" } else { "ice_servers_fetched" });
    let options = DialOptions {
        ice_servers,
        include_loopback: context.include_loopback,
        exclude_cgnat: context.exclude_cgnat,
        timeline: timeline.clone(),
        stock_ice_waits: baseline,
        // Browser video on the media lane: a WebRTC track, or RTP inside the
        // WireGuard tunnel (CMUX_MOBILE_VIDEO_LANE=0 turns it off;
        // CMUX_MOBILE_VIDEO_DROP_PERMILLE simulates a lossy path, CMUX_MOBILE_VIDEO_CAP_KBPS
        // a capped one on WireGuard).
        video_lane: std::env::var("CMUX_MOBILE_VIDEO_LANE").map_or(true, |v| v != "0"),
        video_drop_permille: video_drop_permille(),
        video_cap_bps: video_cap_bps(),
        // A WebRTC media session beside a WireGuard link carries browser
        // video while it works (media_session.rs; CMUX_MOBILE_WEBRTC_MEDIA=0 turns
        // it off).
        webrtc_media: std::env::var("CMUX_MOBILE_WEBRTC_MEDIA").map_or(true, |v| v != "0"),
        ..DialOptions::default()
    };
    let connected = match dial::answer(&signaling, first, events, &options, LinkConfig::default()).await {
        Ok(connected) => connected,
        Err(error) => {
            tracing::warn!(session_id, ?kind, %error, timings = %timeline.summary(), "answer failed");
            return;
        }
    };
    let path = *connected.path.borrow();
    if let Some(cmux_mobile_link::media::MediaLane::Out(video)) = connected.link.media() {
        peer.video = Some(video);
    }
    tracing::info!(session_id, ?kind, ?path, phone = peer.device_id, video = peer.video.is_some(), timings = %timeline.summary(), "link up");
    control::emit(&Event::PhoneUp {
        session_id: session_id.clone(),
        phone_device_id: peer.device_id.clone(),
        transport: control::transport_name(kind).into(),
        path: control::path_name(path).into(),
    });
    // However this task ends (a panic too), the phone's link closes with it.
    let _close = CloseOnDrop(connected.link.clone());
    // The watchers end with this task; the channels are drained after link down.
    let mut watchers = TaskScope::<&'static str>::default();
    let mut channels = TaskScope::<String>::default();
    let mut paths = connected.path.clone();
    let path_session = session_id.clone();
    watchers.spawn("path", async move {
        while paths.changed().await.is_ok() {
            let path = *paths.borrow_and_update();
            // A WireGuard link can move between direct, TURN and TURN over
            // TLS after link up (roams, a direct path found again); this says when.
            tracing::info!(session_id = path_session, ?path, "link path changed");
            control::emit(&Event::PhonePath {
                session_id: path_session.clone(),
                path: control::path_name(path).into(),
            });
        }
    });
    let auth = Arc::new(crate::pairing::LinkAuth::default());
    // The phone may open a WebRTC media session for this link's video.
    let _hybrid = match (&peer.video, connected.webrtc_media) {
        (Some(video), true) => Some(crate::media_session::register(
            &session_id,
            &peer.device_id,
            video.clone(),
            Arc::clone(&auth),
            context.services.pairing.is_some(),
            connected.link.closed_state(),
        )),
        _ => None,
    };
    // The owner removed this phone (Settings > Mobile > Remove): end its link now.
    let mut drops = control::drops();
    let removable = connected.link.clone();
    let phone = peer.device_id.to_lowercase();
    watchers.spawn("removal", async move {
        loop {
            match drops.recv().await {
                Ok(id) if id == phone => {
                    removable.close("removed");
                    return;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            }
        }
    });
    let mut first = true;
    loop {
        let incoming = tokio::select! {
            incoming = connected.link.accept() => match incoming {
                Some(incoming) => incoming,
                None => break,
            },
            ended = channels.ended() => {
                if let Ended::Panicked(service, message) = ended {
                    // A channel task that broke ends this phone's link, not hostd.
                    tracing::error!(session_id, service, message, "a channel task failed; closing the link");
                    connected.link.close("hostd_error");
                }
                continue;
            }
            ended = watchers.ended() => {
                if let Ended::Panicked(watcher, message) = ended {
                    tracing::error!(session_id, watcher, message, "a link watcher failed; closing the link");
                    connected.link.close("hostd_error");
                }
                continue;
            }
        };
        if first {
            first = false;
            timeline.mark("first_channel");
            tracing::info!(session_id, timings = %timeline.summary(), "first channel");
        }
        // In open order: a channel opened after `auth` waits for it. One
        // `auth` runs at a time per link.
        if incoming.service == "auth" && context.services.pairing.is_some() && !auth.try_begin() {
            let service = incoming.service.clone();
            channels.spawn(
                service,
                services::refuse(incoming, "busy", "this iPhone's pairing is already running"),
            );
            continue;
        }
        if incoming.service == "auth" && context.services.pairing.is_none() {
            auth.begin();
        }
        let service = incoming.service.clone();
        channels.spawn(
            service,
            services::serve(Arc::clone(&context.services), peer.clone(), Arc::clone(&auth), incoming),
        );
    }
    let reason = connected.link.closed().await;
    drop(watchers);
    tracing::info!(session_id, reason, "link down");
    control::emit(&Event::PhoneDown { session_id: session_id.clone(), reason });
    // Channel tasks finish their own close (a pairing being saved, an upload's
    // cleanup) after link down, as they did when they ran detached.
    channels
        .drain(|ended| {
            if let Ended::Panicked(service, message) = ended {
                tracing::error!(session_id, service, message, "a channel task failed after link down");
            }
        })
        .await;
}

/// Closes a link when dropped: a link task that ends early or panics leaves
/// no link alive behind it (closing a closed link does nothing).
struct CloseOnDrop(cmux_mobile_link::Link);

impl Drop for CloseOnDrop {
    fn drop(&mut self) {
        self.0.close("hostd_error");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link_pair() -> (cmux_mobile_link::Link, cmux_mobile_link::Link) {
        use cmux_mobile_link::{Link, LinkConfig, Role};
        let (a, b) = tokio::io::duplex(64 * 1024);
        (
            Link::new(a, Role::Phone, LinkConfig::default(), None),
            Link::new(b, Role::Mac, LinkConfig::default(), None),
        )
    }

    /// A phone's task that panics (a frame its code did not expect) closes
    /// that phone's link; another phone's link and hostd keep going.
    #[tokio::test]
    async fn a_failed_phone_task_closes_only_its_link() {
        let (_phone_a, mac_a) = link_pair();
        let (_phone_b, mac_b) = link_pair();
        let mut phones = Phones::default();
        let link = mac_a.clone();
        phones.spawn(PhoneTask::Link { session_id: "a".into() }, async move {
            let _close = CloseOnDrop(link);
            panic!("unexpected frame");
        });
        let link = mac_b.clone();
        let (release, wait) = tokio::sync::oneshot::channel::<()>();
        phones.spawn(PhoneTask::Link { session_id: "b".into() }, async move {
            let _close = CloseOnDrop(link);
            let _ = wait.await;
        });
        assert_eq!(
            phones.ended().await,
            Ended::Panicked(PhoneTask::Link { session_id: "a".into() }, "unexpected frame".into())
        );
        let closed = tokio::time::timeout(Duration::from_secs(5), mac_a.closed()).await;
        assert_eq!(closed.as_deref(), Ok("hostd_error"));
        assert!(mac_b.closed_state().borrow().is_none(), "the other phone's link stays up");
        assert!(mac_b.ping().await.is_ok());
        let _ = release.send(());
        assert_eq!(phones.ended().await, Ended::Finished(PhoneTask::Link { session_id: "b".into() }));
    }

    #[test]
    fn a_4002_close_is_a_removal() {
        assert!(removed("signaling closed by server: 4002 removed"));
        assert!(!removed("signaling closed by server: 4000 replaced"));
        assert!(!removed("signaling closed by server: 4001 moved"));
        assert!(!removed("signaling read failed: 4002"));
        assert!(!removed("signaling socket closed"));
    }

    #[test]
    fn only_a_401_marks_the_token_refused() {
        let refused =
            anyhow::Error::new(cmux_mobile_link::api::ApiError::Status { status: 401, body: String::new() })
                .context("POST /v1/devices");
        assert!(unauthorized(&refused));
        let upgrade = anyhow::Error::new(cmux_mobile_link::signaling::SignalingError::Connect(
            "HTTP error: 401 Unauthorized".into(),
        ));
        assert!(unauthorized(&upgrade));
        let server =
            anyhow::Error::new(cmux_mobile_link::api::ApiError::Status { status: 502, body: String::new() });
        assert!(!unauthorized(&server));
        assert!(!unauthorized(&anyhow::Error::new(cmux_mobile_link::api::ApiError::Http("dns".into()))));
        assert!(!unauthorized(&anyhow::anyhow!("the app sent no access token")));
    }
}

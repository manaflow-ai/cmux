//! WebRTC media sessions beside WireGuard links (PROTOCOL.md "Media
//! session", verify/hybrid-link.md).
//!
//! A phone whose WireGuard link listed `webrtc-media` may open a WebRTC peer
//! connection that carries only that link's browser video. Its first signal
//! is a `webrtc-offer` with `mediaFor: <the link's session id>`. There is no
//! new trust path: the offer is admitted like any dial (the backend's
//! `fromUserId` is the Mac's owner), and it is answered only for a live link
//! of the same phone device that passed pairing (when pairing is on). The
//! session's track becomes a route of that link's media lane
//! ([`cmux_mobile_link::media::VideoOut::add_route`]); it ends with the link, when
//! its peer connection fails or closes, or when the phone opens a newer one.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use cmux_mobile_link::dial::{self, SessionEvents};
use cmux_mobile_link::signaling::{SignalEnvelope, SignalPayload};
use cmux_mobile_link::{DialOptions, SignalingClient, Timeline};
use tokio::sync::watch;

use crate::control::{self, Event};
use crate::host::AnswerContext;

/// How long a media answer may take.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(15);

/// A WireGuard link that may take a media session.
struct Hybrid {
    phone: String,
    video: cmux_mobile_link::media::VideoOut,
    auth: Arc<crate::pairing::LinkAuth>,
    pairing: bool,
    link_closed: watch::Receiver<Option<String>>,
    /// The number of the newest media offer received for this link: an
    /// answer that finishes after a newer offer arrived is dropped (the phone
    /// gave up on it), so it never replaces the newer session.
    offers: Arc<std::sync::atomic::AtomicU64>,
    /// The offer number of the current media session (0: none); a newer one
    /// replaces it.
    current: watch::Sender<u64>,
    /// Which registration this is (a stale registration's drop leaves a newer one).
    token: u64,
}

fn links() -> &'static Mutex<HashMap<String, Hybrid>> {
    static LINKS: OnceLock<Mutex<HashMap<String, Hybrid>>> = OnceLock::new();
    LINKS.get_or_init(Mutex::default)
}

/// Removes the link from the registry when dropped (the link is down).
pub struct Registration {
    session_id: String,
    token: u64,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut links = links().lock().unwrap_or_else(PoisonError::into_inner);
        if links.get(&self.session_id).is_some_and(|link| link.token == self.token) {
            links.remove(&self.session_id);
        }
    }
}

/// The WireGuard link `session_id` of `phone`, with media lane `video`,
/// takes media sessions until the returned registration drops.
pub fn register(
    session_id: &str,
    phone: &str,
    video: cmux_mobile_link::media::VideoOut,
    auth: Arc<crate::pairing::LinkAuth>,
    pairing: bool,
    link_closed: watch::Receiver<Option<String>>,
) -> Registration {
    static TOKENS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let token = TOKENS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    links().lock().unwrap_or_else(PoisonError::into_inner).insert(
        session_id.to_owned(),
        Hybrid {
            phone: phone.to_owned(),
            video,
            auth,
            pairing,
            link_closed,
            offers: Arc::default(),
            current: watch::channel(0).0,
            token,
        },
    );
    Registration { session_id: session_id.to_owned(), token }
}

/// Why a media offer is refused, if it is: the link must be live, belong to
/// the same phone device, and (with pairing on) have passed `auth`.
fn refusal(link: Option<&Hybrid>, from: &str) -> Option<&'static str> {
    let Some(link) = link else { return Some("unknown_link") };
    if link.phone != from {
        return Some("unknown_link");
    }
    if link.link_closed.borrow().is_some() {
        return Some("unknown_link");
    }
    if link.pairing && !link.auth.is_authenticated() {
        return Some("unpaired");
    }
    None
}

/// The media path's wire name for the app (`direct`, `turn`).
fn media_path(path: cmux_mobile_link::LinkPath) -> &'static str {
    control::path_name(path)
}

/// Answers one media session offer (already admitted: same owner).
pub async fn answer(
    signaling: SignalingClient,
    first: SignalEnvelope,
    events: SessionEvents,
    link_session: String,
    context: AnswerContext,
) {
    let session_id = first.session_id.clone();
    let checked = {
        let links = links().lock().unwrap_or_else(PoisonError::into_inner);
        let link = links.get(&link_session);
        match refusal(link, &first.from) {
            Some(code) => Err(code),
            None => {
                let link = link.expect("checked");
                let offer = link.offers.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                Ok((
                    link.video.clone(),
                    link.link_closed.clone(),
                    link.current.clone(),
                    Arc::clone(&link.offers),
                    offer,
                ))
            }
        }
    };
    let (video, mut link_closed, current, offers, offer) = match checked {
        Ok(parts) => parts,
        Err(code) => {
            tracing::warn!(session_id, link_session, code, "refusing a media session");
            signaling.unsubscribe(&session_id);
            let _ =
                signaling.send_signal(&first.from, &session_id, SignalPayload::Bye { reason: code.into() });
            return;
        }
    };
    let timeline = Timeline::new();
    timeline.mark("media_offer_received");
    let (ice_servers, _) = context.ice.servers().await;
    let options = DialOptions {
        ice_servers,
        include_loopback: context.include_loopback,
        exclude_cgnat: context.exclude_cgnat,
        video_drop_permille: crate::host::video_drop_permille(),
        timeout: ANSWER_TIMEOUT,
        timeline: timeline.clone(),
        ..DialOptions::default()
    };
    let session = match dial::webrtc::answer_media(&signaling, first, events, &options).await {
        Ok(session) => session,
        Err(error) => {
            tracing::warn!(session_id, link_session, %error, timings = %timeline.summary(), "media session failed");
            return;
        }
    };
    // The phone opened a newer session while this one was coming up: it
    // gave up on this one.
    if offers.load(std::sync::atomic::Ordering::SeqCst) != offer {
        tracing::info!(session_id, link_session, "media session superseded before it came up");
        return;
    }
    // A newer session for the same link replaces this one.
    current.send_replace(offer);
    let mut replaced = current.subscribe();
    let route = video.add_route(std::sync::Arc::clone(&session.carrier), session.up.clone());
    let mut path = session.path.clone();
    let mut active = video.active();
    tracing::info!(
        session_id,
        link_session,
        path = ?*path.borrow(),
        timings = %timeline.summary(),
        "media session up"
    );
    control::emit(&Event::PhoneMedia {
        session_id: link_session.clone(),
        media_path: media_path(*path.borrow_and_update()).into(),
    });
    let mut kills = kills();
    let reason = loop {
        tokio::select! {
            reason = session.wait_ended() => break reason,
            () = async { let _ = link_closed.wait_for(Option::is_some).await; } => break "link closed".to_owned(),
            () = async { let _ = replaced.wait_for(|current| *current != offer).await; } => {
                break "replaced".to_owned();
            }
            changed = path.changed() => {
                if changed.is_err() {
                    continue;
                }
                let now = *path.borrow_and_update();
                tracing::info!(session_id, link_session, path = ?now, "media session path changed");
                control::emit(&Event::PhoneMedia { session_id: link_session.clone(), media_path: media_path(now).into() });
            }
            changed = active.changed() => {
                if changed.is_ok() {
                    let carrier = (*active.borrow_and_update()).map(cmux_mobile_link::media::CarrierKind::name);
                    tracing::info!(link_session, ?carrier, "browser video route");
                }
            }
            kill = kills.recv() => {
                if matches!(kill, Ok(())) {
                    tracing::warn!(session_id, "killing the media session (SIGUSR2, test support)");
                    session.kill().await;
                }
            }
        }
    };
    drop(route);
    tracing::info!(session_id, link_session, reason, "media session down");
    // Only the current session reports the link's media gone.
    if *current.borrow() == offer {
        current.send_replace(0);
        control::emit(&Event::PhoneMedia { session_id: link_session, media_path: "none".into() });
    }
}

fn kill_sender() -> &'static tokio::sync::broadcast::Sender<()> {
    static KILLS: OnceLock<tokio::sync::broadcast::Sender<()>> = OnceLock::new();
    KILLS.get_or_init(|| tokio::sync::broadcast::channel(4).0)
}

fn kills() -> tokio::sync::broadcast::Receiver<()> {
    kill_sender().subscribe()
}

/// Test and measurement support, on Unix signals to hostd (a rig cannot
/// pass hostd an environment). Off unless hostd's state folder
/// (`CMUX_MOBILE_STATE_DIR`) holds a `test-signals` file when hostd starts (host.rs):
///
/// - `SIGUSR1` toggles a black hole under every WebRTC media track: its RTP
///   and the RTCP it receives vanish while the peer connection stays
///   connected, as when a path dies silently. Video falls back to the
///   tunnel on missing feedback and tries the session again after a backoff.
/// - `SIGUSR2` closes every media session's peer connection, as when it
///   failed: video falls back and the phone dials a new session.
pub fn spawn_test_signals() {
    #[cfg(unix)]
    tokio::spawn(async {
        use tokio::signal::unix::{SignalKind, signal};
        let (Ok(mut usr1), Ok(mut usr2)) =
            (signal(SignalKind::user_defined1()), signal(SignalKind::user_defined2()))
        else {
            return;
        };
        loop {
            tokio::select! {
                Some(()) = usr1.recv() => {
                    let on = !cmux_mobile_link::media::track::blackhole();
                    cmux_mobile_link::media::track::set_blackhole(on);
                    tracing::warn!(on, "WebRTC media black hole (SIGUSR1, test support)");
                }
                Some(()) = usr2.recv() => {
                    let _ = kill_sender().send(());
                }
                else => return,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hybrid(phone: &str, pairing: bool, closed: bool) -> (Hybrid, watch::Sender<Option<String>>) {
        let (closed_tx, link_closed) = watch::channel(closed.then(|| "closed".to_owned()));
        let carrier = Arc::new(NoCarrier);
        let video = cmux_mobile_link::media::VideoOut::start(carrier, Default::default(), None);
        let hybrid = Hybrid {
            phone: phone.into(),
            video,
            auth: Arc::new(crate::pairing::LinkAuth::default()),
            pairing,
            link_closed,
            offers: Arc::default(),
            current: watch::channel(0).0,
            token: 0,
        };
        (hybrid, closed_tx)
    }

    struct NoCarrier;

    impl cmux_mobile_link::media::MediaCarrier for NoCarrier {
        fn kind(&self) -> cmux_mobile_link::media::CarrierKind {
            cmux_mobile_link::media::CarrierKind::WireGuardUdp
        }
        fn twcc_ext_id(&self) -> u8 {
            1
        }
        fn send_rtp<'a>(
            &'a self,
            _: &'a cmux_mobile_link::media::rtp::packet::Packet,
        ) -> futures_util::future::BoxFuture<'a, Result<(), cmux_mobile_link::media::MediaError>> {
            Box::pin(async { Ok(()) })
        }
        fn send_rtcp(
            &self,
            _: cmux_mobile_link::media::RtcpPackets,
        ) -> futures_util::future::BoxFuture<'_, Result<(), cmux_mobile_link::media::MediaError>> {
            Box::pin(async { Ok(()) })
        }
        fn recv_rtp(
            &self,
        ) -> futures_util::future::BoxFuture<'_, Option<cmux_mobile_link::media::rtp::packet::Packet>>
        {
            Box::pin(std::future::pending())
        }
        fn recv_rtcp(
            &self,
        ) -> futures_util::future::BoxFuture<'_, Option<cmux_mobile_link::media::RtcpPackets>> {
            Box::pin(std::future::pending())
        }
    }

    /// No new trust path: only a live link of the same phone device, paired
    /// when pairing is on, takes a media session.
    #[tokio::test]
    async fn a_media_session_needs_a_live_paired_link_of_the_same_phone() {
        assert_eq!(refusal(None, "phone"), Some("unknown_link"));
        let (link, _closed) = hybrid("phone", false, false);
        assert_eq!(refusal(Some(&link), "phone"), None);
        assert_eq!(refusal(Some(&link), "other-phone"), Some("unknown_link"));
        let (link, _closed) = hybrid("phone", false, true);
        assert_eq!(refusal(Some(&link), "phone"), Some("unknown_link"), "a closed link");
        let (link, _closed) = hybrid("phone", true, false);
        assert_eq!(refusal(Some(&link), "phone"), Some("unpaired"));
        link.auth.begin();
        link.auth.end(true);
        assert_eq!(refusal(Some(&link), "phone"), None);
    }
}

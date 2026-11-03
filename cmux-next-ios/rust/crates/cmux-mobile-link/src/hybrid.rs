//! The phone's WebRTC media session beside a WireGuard link
//! (verify/hybrid-link.md, PROTOCOL.md "Media session").
//!
//! WireGuard carries the link: every channel, the input lane and, as its
//! floor, browser video as RTP inside the tunnel. A WebRTC peer connection to
//! the same Mac carries only browser video while it works. [`MediaManager`]
//! owns that peer connection's life:
//!
//! - **Lazy.** Nothing opens until a browser tab wants video
//!   ([`MediaManager::acquire`]) or the app warms it up because the shown
//!   workspace has browser tabs ([`MediaManager::warm`]). The link and the
//!   terminal never wait for it.
//! - **Lingering.** With no visible browser tab for [`LINGER`] (and no warm-up
//!   in force), the session closes.
//! - **Retrying.** A dial that fails, or a session that fails or closes,
//!   is tried again after 1, 2, 4, 8, 16, then every 30 s while it is
//!   wanted; a session that stayed up [`STABLE`] starts over at 1 s.
//! - **One source of the lane.** A connected session's track is added to the
//!   link's media lane ([`crate::media::VideoIn::add_source`]); the Mac moves
//!   video onto it at a keyframe, and back to the tunnel at a keyframe when
//!   it fails.

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::future::BoxFuture;
use tokio::sync::watch;

use crate::api::IceServer;
use crate::dial::{DialOptions, LinkPath};
use crate::link::Link;
use crate::signaling::SignalingClient;

/// How long the session stays open after the last browser tab is hidden.
pub const LINGER: Duration = Duration::from_secs(30);
/// How long a warm-up keeps the session wanted.
pub const WARM_FOR: Duration = Duration::from_secs(60);
/// A session up this long resets the retry backoff.
pub const STABLE: Duration = Duration::from_secs(30);
/// A media dial gives up after this.
pub const DIAL_TIMEOUT: Duration = Duration::from_secs(12);
const BACKOFF: [u64; 6] = [1, 2, 4, 8, 16, 30];
/// How often the session's round trip is read for the status.
const RTT_EVERY: Duration = Duration::from_secs(5);

/// What the phone's status line says about the media session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaStatus {
    /// No session (nothing wants one, or it lingered out).
    Off,
    Connecting,
    /// Connected over `path`; `rtt` is the ICE pair's round trip.
    Up {
        path: LinkPath,
        rtt: Option<Duration>,
    },
    /// The last attempt failed or the session dropped; tried again in `retry_in`.
    Failed {
        reason: String,
        retry_in: Duration,
    },
}

/// The current signaling socket for the link's team and device (the warm
/// pool's, which may have been replaced since the link was dialed).
pub type SignalingSource = Arc<dyn Fn() -> BoxFuture<'static, Option<SignalingClient>> + Send + Sync>;
/// Fresh ICE servers (TURN credentials expire).
pub type IceSource = Arc<dyn Fn() -> BoxFuture<'static, Vec<IceServer>> + Send + Sync>;

pub struct MediaConfig {
    pub link: Link,
    /// The Mac's device id and the WireGuard link's session id.
    pub mac: String,
    pub link_session: String,
    pub signaling: SignalingSource,
    pub ice: IceSource,
    /// The link's dial options (relay only, block UDP, loopback, CGNAT).
    pub options: DialOptions,
    /// How long the session stays after the last browser tab is hidden
    /// ([`LINGER`]; tests shorten it).
    pub linger: Duration,
}

#[derive(Debug, Clone, Copy, Default)]
struct Demand {
    users: usize,
    warm_until: Option<Instant>,
}

impl Demand {
    fn wanted(&self, now: Instant) -> bool {
        self.users > 0 || self.warm_until.is_some_and(|until| until > now)
    }
}

/// The phone's media session for one WireGuard link; see the module docs.
/// Cloning shares it. It ends with the link.
#[derive(Clone)]
pub struct MediaManager {
    demand: Arc<watch::Sender<Demand>>,
    status: watch::Receiver<MediaStatus>,
    kill: Arc<tokio::sync::Notify>,
}

/// One user's hold (a visible browser tab); dropping it releases it.
pub struct MediaDemand {
    demand: Arc<watch::Sender<Demand>>,
}

impl Drop for MediaDemand {
    fn drop(&mut self) {
        self.demand.send_modify(|d| d.users = d.users.saturating_sub(1));
    }
}

impl MediaManager {
    /// Starts the manager; nothing opens until something wants video.
    pub fn start(config: MediaConfig) -> Self {
        let (demand, demand_rx) = watch::channel(Demand::default());
        let (status_tx, status) = watch::channel(MediaStatus::Off);
        let kill = Arc::new(tokio::sync::Notify::new());
        tokio::spawn(run(config, demand_rx, status_tx, Arc::clone(&kill)));
        let manager = Self { demand: Arc::new(demand), status, kill };
        manager.spawn_dev_kills();
        manager
    }

    /// Dev hook (simulators and rigs; a launch variable, never set on a
    /// shipped phone): `CMUX_MOBILE_DEV_KILL_MEDIA_EVERY_S=N` kills each
    /// session N seconds after it comes up, so the media lane switches
    /// route (into the tunnel, then back onto the next session) while a
    /// tab is shown (verify/browser-freeze).
    fn spawn_dev_kills(&self) {
        let Some(every) = std::env::var("CMUX_MOBILE_DEV_KILL_MEDIA_EVERY_S")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|s| *s > 0)
        else {
            return;
        };
        let mut status = self.status.clone();
        let kill = Arc::downgrade(&self.kill);
        tokio::spawn(async move {
            loop {
                if status.wait_for(|s| matches!(s, MediaStatus::Up { .. })).await.is_err() {
                    return;
                }
                // An intentional, bounded dev delay on the runtime's clock.
                tokio::time::sleep(Duration::from_secs(every)).await;
                let Some(kill) = kill.upgrade() else { return };
                // The session that came up may have ended meanwhile: a permit
                // stored now would kill the next one the moment it is up.
                if !matches!(*status.borrow(), MediaStatus::Up { .. }) {
                    continue;
                }
                tracing::info!(every_s = every, "dev: killing the media session");
                // A permit, not notify_waiters: the hold loop may be in another
                // arm right now (the RTT ticker), and a wake-up only for parked
                // waiters would be lost.
                kill.notify_one();
                if status.wait_for(|s| !matches!(s, MediaStatus::Up { .. })).await.is_err() {
                    return;
                }
            }
        });
    }

    /// A browser tab shows video: open the session (if not open) and keep
    /// it while the returned hold lives.
    pub fn acquire(&self) -> MediaDemand {
        self.demand.send_modify(|d| d.users += 1);
        MediaDemand { demand: Arc::clone(&self.demand) }
    }

    /// The shown workspace has browser tabs: open the session ahead of the
    /// first one, and keep it for [`WARM_FOR`].
    pub fn warm(&self) {
        let until = Instant::now() + WARM_FOR;
        self.demand.send_modify(|d| d.warm_until = Some(d.warm_until.map_or(until, |u| u.max(until))));
    }

    pub fn status(&self) -> watch::Receiver<MediaStatus> {
        self.status.clone()
    }

    /// Test and measurement support: closes the session's peer connection
    /// at once, as when it failed (the Mac sees it close and moves video to
    /// the tunnel; the manager dials again as after any failure).
    #[doc(hidden)]
    pub fn kill(&self) {
        // Only a session up now; no permit is kept for a later one.
        self.kill.notify_waiters();
    }
}

async fn run(
    config: MediaConfig,
    mut demand: watch::Receiver<Demand>,
    status: watch::Sender<MediaStatus>,
    kill: Arc<tokio::sync::Notify>,
) {
    let Some(crate::media::MediaLane::In(lane)) = config.link.media() else {
        tracing::info!("no media lane on this link; no media session");
        return;
    };
    let mut closed = config.link.closed_state();
    let mut attempt = 0usize;
    loop {
        // Wait until something wants video.
        status.send_replace(MediaStatus::Off);
        if !wait_wanted(&mut demand, &mut closed).await {
            return;
        }
        status.send_replace(MediaStatus::Connecting);
        let dialed = tokio::select! {
            dialed = dial(&config) => dialed,
            () = closed_now(&mut closed) => return,
        };
        let failure = match dialed {
            Ok(session) => {
                tracing::info!(session = session.session_id, "media session up");
                let source = lane.add_source(
                    Arc::clone(&session.carrier),
                    Some(config.link.rtt()),
                    Some(config.link.closed_state()),
                );
                let since = Instant::now();
                let outcome = hold(&session, config.linger, &mut demand, &mut closed, &status, &kill).await;
                drop(source);
                if since.elapsed() >= STABLE {
                    attempt = 0;
                }
                match outcome {
                    Held::LinkClosed => return,
                    Held::Unwanted => {
                        tracing::info!(
                            session = session.session_id,
                            "media session closed: no browser tab shown"
                        );
                        attempt = 0;
                        None
                    }
                    Held::Ended(reason) => {
                        tracing::info!(session = session.session_id, reason, "media session ended");
                        Some(reason)
                    }
                }
            }
            Err(error) => {
                tracing::info!(%error, "media session did not open; video stays in the tunnel");
                Some(error.to_string())
            }
        };
        let Some(reason) = failure else { continue };
        let retry_in = Duration::from_secs(BACKOFF[attempt.min(BACKOFF.len() - 1)]);
        attempt += 1;
        status.send_replace(MediaStatus::Failed { reason, retry_in });
        tokio::select! {
            () = tokio::time::sleep(retry_in) => {}
            () = closed_now(&mut closed) => return,
        }
    }
}

/// Resolves true once video is wanted, false when the link closed first.
async fn wait_wanted(
    demand: &mut watch::Receiver<Demand>,
    closed: &mut watch::Receiver<Option<String>>,
) -> bool {
    loop {
        let now = Instant::now();
        if demand.borrow_and_update().wanted(now) {
            return true;
        }
        if closed.borrow().is_some() {
            return false;
        }
        tokio::select! {
            changed = demand.changed() => if changed.is_err() { return false },
            () = closed_now(closed) => return false,
        }
    }
}

async fn dial(config: &MediaConfig) -> Result<crate::dial::webrtc::MediaSession, crate::DialError> {
    let Some(signaling) = (config.signaling)().await else {
        return Err(crate::DialError::Signaling("no signaling socket".into()));
    };
    let ice_servers = (config.ice)().await;
    let options = DialOptions {
        ice_servers,
        timeout: DIAL_TIMEOUT,
        timeline: crate::Timeline::new(),
        ..config.options.clone()
    };
    crate::dial::webrtc::dial_media(&signaling, &config.mac, &config.link_session, &options).await
}

/// Resolves once the link closed.
async fn closed_now(closed: &mut watch::Receiver<Option<String>>) {
    let _ = closed.wait_for(Option::is_some).await;
}

enum Held {
    LinkClosed,
    Unwanted,
    Ended(String),
}

/// Keeps `session` while it works and something wants video (or lingers).
async fn hold(
    session: &crate::dial::webrtc::MediaSession,
    linger: Duration,
    demand: &mut watch::Receiver<Demand>,
    closed: &mut watch::Receiver<Option<String>>,
    status: &watch::Sender<MediaStatus>,
    kill: &tokio::sync::Notify,
) -> Held {
    let mut path = session.path.clone();
    let mut rtt = session.rtt().await;
    status.send_replace(MediaStatus::Up { path: *path.borrow_and_update(), rtt });
    let mut idle_since: Option<Instant> = None;
    let mut ticker = tokio::time::interval(RTT_EVERY);
    ticker.tick().await;
    loop {
        let now = Instant::now();
        let wanted = demand.borrow_and_update().wanted(now);
        idle_since = if wanted { None } else { Some(idle_since.unwrap_or(now)) };
        // Wake when the warm-up runs out, or when the linger ends.
        let warm_ends = demand.borrow().warm_until.filter(|until| *until > now);
        let linger_ends = idle_since.map(|since| since + linger);
        if linger_ends.is_some_and(|at| at <= now) {
            return Held::Unwanted;
        }
        let wake = [warm_ends, linger_ends].into_iter().flatten().min();
        let timer = async {
            match wake {
                Some(at) => tokio::time::sleep_until(at.into()).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            () = closed_now(closed) => return Held::LinkClosed,
            reason = session.wait_ended() => return Held::Ended(reason),
            () = kill.notified() => {
                tracing::info!("media session killed (test)");
                session.kill().await;
                return Held::Ended("killed (test)".into());
            }
            changed = demand.changed() => if changed.is_err() { return Held::LinkClosed },
            changed = path.changed() => {
                if changed.is_ok() {
                    status.send_replace(MediaStatus::Up { path: *path.borrow_and_update(), rtt });
                }
            }
            _ = ticker.tick() => {
                // A new round trip is news only when it moved (by 20 % and
                // 2 ms): every status change redraws the app's line.
                let now = session.rtt().await;
                let moved = match (rtt, now) {
                    (Some(old), Some(new)) => {
                        let diff = old.abs_diff(new);
                        diff >= Duration::from_millis(2) && diff * 5 >= old
                    }
                    (old, new) => old.is_some() != new.is_some(),
                };
                if moved {
                    rtt = now;
                    status.send_replace(MediaStatus::Up { path: *path.borrow(), rtt });
                }
            }
            () = timer => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_warm_up_wants_video_until_it_runs_out() {
        let now = Instant::now();
        let demand = Demand { users: 0, warm_until: Some(now + WARM_FOR) };
        assert!(demand.wanted(now));
        assert!(!demand.wanted(now + WARM_FOR));
        assert!(Demand { users: 1, warm_until: None }.wanted(now));
        assert!(!Demand::default().wanted(now));
    }
}

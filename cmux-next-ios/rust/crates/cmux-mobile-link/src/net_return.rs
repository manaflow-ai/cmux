//! Network-return watch: tells the app the network is back within about a
//! second when iOS reports no path change (an elevator, a cell dead zone, a
//! captive portal letting go: the radio stays "satisfied" the whole time).
//!
//! Before it the only signals were the link's own retry backoff (its tail
//! is 10, 15, then 30 s), a standby link's probe (at most 45 s, then the
//! Mac's keepalive closes its end) and the presence socket's reconnect (2,
//! 3, then 5 s, each attempt able to hang 10 s on the dead path). The
//! iOS reliability matrix's `network_flaps` cell measured the result:
//! no-path-change returns reconnected at a p95 of seconds and a worst case
//! up to its 30 s bound.
//!
//! While a link is down and the app is in front, [`watch`] opens a TCP
//! connection to the cmux service every [`EVERY`], each bounded by
//! [`PROBE_TIMEOUT`] (under [`EVERY`], so a hanging probe never stretches
//! the beat). The first that connects after one that did not is the
//! network back ([`Return::Back`]); the app then redials every waiting link
//! at once, as on a path change. One that connects at once means the
//! network was never down (the Mac is the problem): [`Return::NeverDown`],
//! and the app stops watching. Cost: one SYN a second while dark (about
//! 60 bytes, nothing comes back), one handshake and close when it returns,
//! nothing while the link is up or the app is in the background.

use std::future::Future;
use std::time::Duration;

use tokio::time::Instant;

/// How often the watch probes while the network is down.
pub const EVERY: Duration = Duration::from_secs(1);
/// One probe's bound: a dark path never answers, so this is what a probe
/// costs there. Under [`EVERY`], so the beat stays one a second.
pub const PROBE_TIMEOUT: Duration = Duration::from_millis(900);

/// What a watch ended on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Return {
    /// A probe got through after at least one that did not: the network is
    /// back. `down_for`: from the first failed probe to the one that got
    /// through; `probes`: how many were sent in all.
    Back { down_for: Duration, probes: u32 },
    /// The first probe got through: the network was not down.
    NeverDown,
    /// Still down at the watch's bound.
    StillDown { probes: u32 },
}

/// Probes with `probe` every `every` (each bounded by `timeout`) until one
/// gets through or `max_wait` passes. See the module docs.
pub async fn watch<F, Fut>(mut probe: F, every: Duration, timeout: Duration, max_wait: Duration) -> Return
where
    F: FnMut() -> Fut,
    Fut: Future<Output = bool>,
{
    let start = Instant::now();
    let mut probes = 0u32;
    let mut first_failure: Option<Instant> = None;
    loop {
        let round = Instant::now();
        probes = probes.saturating_add(1);
        let through = tokio::time::timeout(timeout, probe()).await.unwrap_or(false);
        if through {
            return match first_failure {
                None => Return::NeverDown,
                Some(at) => Return::Back { down_for: round.saturating_duration_since(at), probes },
            };
        }
        first_failure.get_or_insert(round);
        let next = round + every;
        if next.saturating_duration_since(start) > max_wait {
            return Return::StillDown { probes };
        }
        tokio::time::sleep_until(next).await;
    }
}

/// The cmux service's host and port from its base URL (`https://host` is
/// port 443, `http://host` 80).
pub fn service_address(base_url: &str) -> Option<(String, u16)> {
    let url = url::Url::parse(base_url).ok()?;
    let host = url.host_str()?.to_owned();
    let port = url.port_or_known_default()?;
    Some((host, port))
}

/// Whether a TCP connection to `host:port` opens (name resolution included:
/// a dark path fails that too, or the OS answers from its cache).
pub async fn tcp_reachable(host: &str, port: u16) -> bool {
    tokio::net::TcpStream::connect((host, port)).await.is_ok()
}

/// [`watch`] against the cmux service at `base_url`, on the default beat.
/// A base URL with no host is never reachable: the watch runs to its bound.
pub async fn wait_for_service(base_url: &str, max_wait: Duration) -> Return {
    let address = service_address(base_url);
    watch(
        || {
            let address = address.clone();
            async move {
                match address {
                    Some((host, port)) => tcp_reachable(&host, port).await,
                    None => false,
                }
            }
        },
        EVERY,
        PROBE_TIMEOUT,
        max_wait,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A path dark until `back` (probes hang), then answering in `rtt`.
    fn path(
        start: Instant,
        back: Duration,
        rtt: Duration,
        sent: Arc<AtomicU32>,
    ) -> impl FnMut() -> std::pin::Pin<Box<dyn Future<Output = bool> + Send>> {
        move || {
            sent.fetch_add(1, Ordering::SeqCst);
            let dark = Instant::now() < start + back;
            Box::pin(async move {
                if dark {
                    std::future::pending::<()>().await;
                }
                tokio::time::sleep(rtt).await;
                true
            })
        }
    }

    #[tokio::test(start_paused = true)]
    async fn an_up_network_is_never_down_after_one_probe() {
        let sent = Arc::new(AtomicU32::new(0));
        let start = Instant::now();
        let got = watch(
            path(start, Duration::ZERO, Duration::from_millis(80), Arc::clone(&sent)),
            EVERY,
            PROBE_TIMEOUT,
            Duration::from_secs(30),
        )
        .await;
        assert_eq!(got, Return::NeverDown);
        assert_eq!(sent.load(Ordering::SeqCst), 1);
    }

    /// The elevator: dark 30 s, back with no path event. The watch says so
    /// within one beat and one round trip of the network returning, for
    /// every phase of the return against the beat.
    #[tokio::test(start_paused = true)]
    async fn a_return_is_seen_within_one_beat_and_a_round_trip() {
        let rtt = Duration::from_millis(80);
        for offset_ms in (0..1000).step_by(50) {
            let start = Instant::now();
            let back = Duration::from_secs(30) + Duration::from_millis(offset_ms);
            let sent = Arc::new(AtomicU32::new(0));
            let got = watch(
                path(start, back, rtt, Arc::clone(&sent)),
                EVERY,
                PROBE_TIMEOUT,
                Duration::from_secs(120),
            )
            .await;
            let seen = start.elapsed();
            assert!(matches!(got, Return::Back { .. }), "{got:?}");
            assert!(seen >= back, "seen before the network was back: {seen:?} < {back:?}");
            assert!(seen <= back + EVERY + rtt, "seen {:?} after the return", seen - back);
            // One probe a beat, no more: the dark costs one SYN a second.
            let beats = u32::try_from(seen.as_millis() / EVERY.as_millis()).unwrap() + 1;
            assert!(
                sent.load(Ordering::SeqCst) <= beats,
                "{} probes in {beats} beats",
                sent.load(Ordering::SeqCst)
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_network_still_down_stops_at_the_bound() {
        let sent = Arc::new(AtomicU32::new(0));
        let start = Instant::now();
        let got = watch(
            path(start, Duration::from_secs(3600), Duration::ZERO, Arc::clone(&sent)),
            EVERY,
            PROBE_TIMEOUT,
            Duration::from_secs(10),
        )
        .await;
        assert_eq!(got, Return::StillDown { probes: 11 });
        // A probe at 0, 1, ... 10 s: the last beat inside the bound.
        assert!(start.elapsed() <= Duration::from_secs(11));
    }

    #[test]
    fn the_service_address_comes_from_the_base_url() {
        assert_eq!(service_address("https://api.cmux.dev"), Some(("api.cmux.dev".into(), 443)));
        assert_eq!(service_address("http://127.0.0.1:8787/x"), Some(("127.0.0.1".into(), 8787)));
        assert_eq!(service_address("not a url"), None);
    }

    /// The real probe on loopback: a listening port is reachable at once,
    /// a closed one is not, and a watch on it ends on its bound.
    #[tokio::test]
    async fn the_tcp_probe_reads_a_real_socket() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(tcp_reachable("127.0.0.1", port).await);
        assert_eq!(
            wait_for_service(&format!("http://127.0.0.1:{port}"), Duration::from_secs(3)).await,
            Return::NeverDown
        );
        drop(listener);
        assert!(!tcp_reachable("127.0.0.1", port).await);
    }
}

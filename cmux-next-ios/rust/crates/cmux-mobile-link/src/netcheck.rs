//! Netcheck: this device's round trip to each Durable Object region, which
//! the Worker uses to place a session's relay (PROTOCOL.md "Relay
//! placement", RFD 0142 O3).
//!
//! `GET /v1/netcheck/:region` is a WebSocket that answers `ping` with
//! `pong`. A measurement opens all nine regions at once, each bounded by
//! [`REGION_TIMEOUT`], sends [`PINGS`] pings in turn and keeps the least
//! round trip (the upgrade itself is not counted). The result is cached per
//! service, build space and network ([`network_fingerprint`]) for
//! [`TTL`], and reported as `netcheck=<region>:<ms>,...` on the signal
//! socket's URL (and on a relay join, [`append_query`]).
//!
//! It never delays a connect: a signal connect reads only what is cached,
//! then starts a measurement in the background when the cache has none for
//! this network ([`refresh_in_background`]). The first connect on a new
//! network goes out without it; the next one carries it. A Worker without
//! netcheck (an older one answers `404`, the kill switch `503`) is
//! remembered for [`TTL`] and not asked again meanwhile.
//!
//! Off by default: nothing is measured or sent unless [`SWITCH_ENV`] is "1"
//! (or a host turns it on with [`set_enabled`]). With it off, the signal
//! socket's URL and the relay join's are byte for byte what they were.
//!
//! Wire: `netcheck=` is an optional query parameter both routes already
//! define (PROTOCOL.md "Relay placement"). A Worker that does not know it
//! ignores it (it reads only `deviceId`), and a client that does not send it
//! is placed by geography as before; no frame, header or status changes.

use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::net::IpAddr;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::build_space::BuildSpace;

/// The Worker's Durable Object regions, in the order they are reported.
pub const REGIONS: [&str; 9] = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"];
/// One region's whole measurement (upgrade and pings); a region past it is left out.
pub const REGION_TIMEOUT: Duration = Duration::from_secs(3);
/// Pings per region; the least round trip counts.
pub const PINGS: usize = 3;
/// How long a measurement stands for its network.
pub const TTL: Duration = Duration::from_secs(30 * 60);
/// The longest `netcheck` value the Worker reads.
pub const MAX_VALUE_LEN: usize = 256;
/// The switch: "1" turns netcheck on (measure, and report on the signal
/// socket and the relay join). Anything else, or unset, leaves it off.
pub const SWITCH_ENV: &str = "CMUX_MOBILE_NETCHECK";

/// 0: follow [`SWITCH_ENV`]; 1: off; 2: on.
static OVERRIDE: AtomicU8 = AtomicU8::new(0);
static FROM_ENV: LazyLock<bool> = LazyLock::new(|| std::env::var(SWITCH_ENV).is_ok_and(|v| v.trim() == "1"));

/// Whether netcheck is on: [`set_enabled`] when a host set it, else [`SWITCH_ENV`].
pub fn enabled() -> bool {
    match OVERRIDE.load(Ordering::Relaxed) {
        1 => false,
        2 => true,
        _ => *FROM_ENV,
    }
}

/// Turn netcheck on or off for this process (`None`: back to [`SWITCH_ENV`]).
pub fn set_enabled(on: Option<bool>) {
    OVERRIDE.store(
        match on {
            None => 0,
            Some(false) => 1,
            Some(true) => 2,
        },
        Ordering::Relaxed,
    );
}

/// One measurement: the least round trip to each region that answered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Netcheck {
    /// `(region, ms)`, in [`REGIONS`] order.
    pub rtt_ms: Vec<(&'static str, u32)>,
}

impl Netcheck {
    /// From round trips by region; unknown regions are dropped.
    pub fn from_rtts<'a>(rtts: impl IntoIterator<Item = (&'a str, Duration)>) -> Self {
        let by_region: HashMap<&str, Duration> = rtts.into_iter().collect();
        let rtt_ms = REGIONS
            .iter()
            .filter_map(|region| by_region.get(region).map(|rtt| (*region, millis(*rtt))))
            .collect();
        Self { rtt_ms }
    }

    /// The home region: the least round trip (the first in [`REGIONS`] order on a tie).
    pub fn home(&self) -> Option<&'static str> {
        self.rtt_ms.iter().min_by_key(|(_, ms)| *ms).map(|(region, _)| *region)
    }

    /// `wnam:31,enam:72`: the `netcheck` query value, at most
    /// [`MAX_VALUE_LEN`] characters (entries past it are left out), or
    /// `None` when no region answered.
    pub fn value(&self) -> Option<String> {
        let mut out = String::new();
        for (region, ms) in &self.rtt_ms {
            let entry = format!("{region}:{ms}");
            let len = out.len() + usize::from(!out.is_empty()) + entry.len();
            if len > MAX_VALUE_LEN {
                break;
            }
            if !out.is_empty() {
                out.push(',');
            }
            out.push_str(&entry);
        }
        (!out.is_empty()).then_some(out)
    }
}

/// Whole milliseconds, rounded, at least 1 (a round trip is never free).
fn millis(rtt: Duration) -> u32 {
    let ms = (rtt.as_micros() + 500) / 1000;
    u32::try_from(ms).unwrap_or(u32::MAX).max(1)
}

/// Why a measurement has no result.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NetcheckError {
    /// The Worker has no netcheck (`404` from an older one, `503` from the kill switch).
    #[error("the service has no netcheck (HTTP {0})")]
    Unsupported(u16),
    /// No region answered within its timeout.
    #[error("no netcheck region answered")]
    NoAnswer,
    #[error("bad netcheck URL: {0}")]
    BadUrl(String),
}

/// What one region did.
#[derive(Debug)]
enum RegionOutcome {
    Rtt(Duration),
    Status(u16),
    Failed,
}

/// `https://host` → `wss://host/v1/netcheck/<region>`.
pub fn region_url(base_url: &str, region: &str) -> Result<String, NetcheckError> {
    let base = base_url.trim_end_matches('/');
    let ws = if let Some(rest) = base.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = base.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if base.starts_with("ws://") || base.starts_with("wss://") {
        base.to_owned()
    } else {
        return Err(NetcheckError::BadUrl(base_url.to_owned()));
    };
    Ok(format!("{ws}/v1/netcheck/{region}"))
}

/// Measure every region of `base_url` at once, each within `timeout`,
/// leaving this device as `egress` says (the signal socket's proxy and trust).
pub async fn measure(
    base_url: &str,
    token: &str,
    build_space: Option<&BuildSpace>,
    egress: &crate::egress::Egress,
    timeout: Duration,
) -> Result<Netcheck, NetcheckError> {
    crate::install_crypto_provider();
    let mut probes = Vec::with_capacity(REGIONS.len());
    for region in REGIONS {
        let url = region_url(base_url, region)?;
        let mut request = url.into_client_request().map_err(|e| NetcheckError::BadUrl(e.to_string()))?;
        let headers = request.headers_mut();
        headers.insert(
            "authorization",
            format!("Bearer {token}")
                .parse()
                .map_err(|_| NetcheckError::BadUrl("token is not a header value".into()))?,
        );
        if let Some(space) = build_space {
            headers.insert(
                crate::build_space::HEADER,
                space
                    .as_str()
                    .parse()
                    .map_err(|_| NetcheckError::BadUrl("build space is not a header value".into()))?,
            );
        }
        probes.push(async move {
            let outcome =
                tokio::time::timeout(timeout, probe(request, egress)).await.unwrap_or(RegionOutcome::Failed);
            (region, outcome)
        });
    }
    let outcomes = futures_util::future::join_all(probes).await;
    let mut unsupported = None;
    let mut rtts = Vec::new();
    for (region, outcome) in outcomes {
        match outcome {
            RegionOutcome::Rtt(rtt) => rtts.push((region, rtt)),
            RegionOutcome::Status(status @ (404 | 503)) => unsupported = Some(status),
            RegionOutcome::Status(_) | RegionOutcome::Failed => {}
        }
    }
    if rtts.is_empty() {
        return Err(unsupported.map_or(NetcheckError::NoAnswer, NetcheckError::Unsupported));
    }
    Ok(Netcheck::from_rtts(rtts))
}

/// One region: upgrade, then [`PINGS`] pings in turn; the least round trip.
async fn probe(
    request: tokio_tungstenite::tungstenite::handshake::client::Request,
    egress: &crate::egress::Egress,
) -> RegionOutcome {
    let mut socket = match crate::egress::connect_websocket(request, egress).await {
        Ok((socket, _)) => socket,
        Err(crate::egress::WebSocketError::Upgrade(tokio_tungstenite::tungstenite::Error::Http(
            response,
        ))) => {
            return RegionOutcome::Status(response.status().as_u16());
        }
        Err(_) => return RegionOutcome::Failed,
    };
    let mut best: Option<Duration> = None;
    'pings: for _ in 0..PINGS {
        let sent = Instant::now();
        if socket.send(Message::Text("ping".into())).await.is_err() {
            break;
        }
        loop {
            match socket.next().await {
                Some(Ok(Message::Text(text))) if text.as_str() == "pong" => {
                    let rtt = sent.elapsed();
                    best = Some(best.map_or(rtt, |b| b.min(rtt)));
                    break;
                }
                // Control frames (a WebSocket ping) are not the answer.
                Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => {}
                _ => break 'pings,
            }
        }
    }
    let _ = socket.close(None).await;
    best.map_or(RegionOutcome::Failed, RegionOutcome::Rtt)
}

/// This device's network as the link sees it: its interfaces' subnets
/// (`cmux_transport::local_networks`, what the path selector reads), not
/// their addresses, so a privacy address rotating on the same network keeps
/// the fingerprint. Loopback, link-local and overlay (Tailscale) addresses
/// are left out. A roam to another network changes it.
pub fn network_fingerprint() -> u64 {
    fingerprint_of(&cmux_transport::local_networks())
}

fn fingerprint_of(networks: &[cmux_transport::LocalNetwork]) -> u64 {
    let mut subnets: Vec<(String, IpAddr, u8)> = networks
        .iter()
        .filter(|n| counts(n.address))
        .map(|n| (n.interface.clone(), masked(n.address, n.prefix), n.prefix))
        .collect();
    subnets.sort();
    subnets.dedup();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    subnets.hash(&mut hasher);
    hasher.finish()
}

fn counts(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            !(v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() || (a == 100 && (b & 0xc0) == 64))
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            !(v6.is_loopback()
                || v6.is_unspecified()
                || (s[0] & 0xffc0) == 0xfe80
                || (s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0))
        }
    }
}

fn masked(ip: IpAddr, prefix: u8) -> IpAddr {
    match ip {
        IpAddr::V4(v4) => {
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix.min(32))).unwrap_or(0);
            IpAddr::V4((u32::from(v4) & mask).into())
        }
        IpAddr::V6(v6) => {
            let mask = u128::MAX.checked_shl(128 - u32::from(prefix.min(128))).unwrap_or(0);
            IpAddr::V6((u128::from(v6) & mask).into())
        }
    }
}

/// Which measurement: the service, its build space and the network.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheKey {
    pub base_url: String,
    pub build_space: Option<String>,
    pub network: u64,
}

impl CacheKey {
    pub fn new(base_url: &str, build_space: Option<&BuildSpace>, network: u64) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_owned(),
            build_space: build_space.map(|s| s.as_str().to_owned()),
            network,
        }
    }
}

#[derive(Debug, Clone)]
struct Entry {
    /// `None`: the service has no netcheck.
    result: Option<Netcheck>,
    at: Instant,
    /// A roam since: measure again, and keep using it until then.
    stale: bool,
}

/// Measurements by [`CacheKey`], each for [`Cache::ttl`].
#[derive(Debug)]
pub struct Cache {
    ttl: Duration,
    entries: HashMap<CacheKey, Entry>,
    in_flight: HashSet<CacheKey>,
}

impl Cache {
    pub fn new(ttl: Duration) -> Self {
        Self { ttl, entries: HashMap::new(), in_flight: HashSet::new() }
    }

    /// The measurement for `key` while it is younger than the TTL.
    pub fn get(&self, key: &CacheKey, now: Instant) -> Option<&Netcheck> {
        self.entries
            .get(key)
            .filter(|e| now.saturating_duration_since(e.at) < self.ttl)
            .and_then(|e| e.result.as_ref())
    }

    /// Whether `key` needs a measurement: none, an expired or stale one,
    /// and none already running.
    pub fn wants(&self, key: &CacheKey, now: Instant) -> bool {
        if self.in_flight.contains(key) {
            return false;
        }
        self.entries.get(key).is_none_or(|e| e.stale || now.saturating_duration_since(e.at) >= self.ttl)
    }

    /// Mark a measurement for `key` as running; false when one already is.
    pub fn begin(&mut self, key: &CacheKey) -> bool {
        self.in_flight.insert(key.clone())
    }

    /// A measurement's end: `Ok` is stored, `Unsupported` is remembered (no
    /// value, no retry until the TTL passes), any other failure keeps what
    /// was there.
    pub fn finish(&mut self, key: &CacheKey, result: Result<Netcheck, NetcheckError>, now: Instant) {
        self.in_flight.remove(key);
        let result = match result {
            Ok(netcheck) => Some(netcheck),
            Err(NetcheckError::Unsupported(_)) => None,
            Err(_) => return,
        };
        self.entries.insert(key.clone(), Entry { result, at: now, stale: false });
        let ttl = self.ttl;
        self.entries.retain(|_, e| now.saturating_duration_since(e.at) < ttl);
    }

    /// The network changed: every entry is measured again at its next use,
    /// and used meanwhile (a roam back to a known network keeps its value).
    pub fn network_changed(&mut self) {
        for entry in self.entries.values_mut() {
            entry.stale = true;
        }
    }
}

static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(|| Mutex::new(Cache::new(TTL)));

fn cache() -> std::sync::MutexGuard<'static, Cache> {
    CACHE.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The cached `netcheck` value for `base_url` on this network, if any (and
/// none while the switch is off).
pub fn cached_value(base_url: &str, build_space: Option<&BuildSpace>) -> Option<String> {
    if !enabled() || !worth_measuring(base_url) {
        return None;
    }
    let key = CacheKey::new(base_url, build_space, network_fingerprint());
    cache().get(&key, Instant::now()).and_then(Netcheck::value)
}

/// The home region (least round trip) cached for `base_url` on this network.
pub fn cached_home(base_url: &str, build_space: Option<&BuildSpace>) -> Option<&'static str> {
    let key = CacheKey::new(base_url, build_space, network_fingerprint());
    cache().get(&key, Instant::now()).and_then(Netcheck::home)
}

/// Add `netcheck=<value>` to `url` (a signal socket or relay join URL) when
/// this network has a cached measurement for `base_url`.
pub fn append_query(url: &mut String, base_url: &str, build_space: Option<&BuildSpace>) {
    with_value(url, cached_value(base_url, build_space).as_deref());
}

/// Add `netcheck=<value>` to `url` when there is a value. The value is
/// `region:ms` pairs only (lowercase letters, digits, `:` and `,`), so it
/// needs no escaping.
pub fn with_value(url: &mut String, value: Option<&str>) {
    if let Some(value) = value.filter(|v| !v.is_empty()) {
        url.push(if url.contains('?') { '&' } else { '?' });
        url.push_str("netcheck=");
        url.push_str(value);
    }
}

/// Start a measurement for `base_url` on this network in the background
/// when the cache has none (or an expired or stale one) and none is
/// running. Returns at once; never waits on the measurement.
pub fn refresh_in_background(
    base_url: &str,
    token: &str,
    build_space: Option<&BuildSpace>,
    egress: &crate::egress::Egress,
) {
    if !enabled() || !worth_measuring(base_url) {
        return;
    }
    let Ok(runtime) = tokio::runtime::Handle::try_current() else {
        return;
    };
    let key = CacheKey::new(base_url, build_space, network_fingerprint());
    {
        let mut cache = cache();
        if !cache.wants(&key, Instant::now()) || !cache.begin(&key) {
            return;
        }
    }
    let base_url = base_url.to_owned();
    let token = token.to_owned();
    let build_space = build_space.cloned();
    let egress = egress.clone();
    runtime.spawn(async move {
        let result = measure(&base_url, &token, build_space.as_ref(), &egress, REGION_TIMEOUT).await;
        match &result {
            Ok(netcheck) => tracing::debug!(home = ?netcheck.home(), value = ?netcheck.value(), "netcheck"),
            Err(error) => tracing::debug!(%error, "netcheck"),
        }
        cache().finish(&key, result, Instant::now());
    });
}

/// The device's network changed: measure again at the next connect.
pub fn network_changed() {
    cache().network_changed();
}

/// A netcheck only means something against the real service: a loopback
/// or `localhost` host (tests, a local Worker) is never measured.
fn worth_measuring(base_url: &str) -> bool {
    let rest = base_url.split_once("://").map_or(base_url, |(_, rest)| rest);
    let authority = rest.split('/').next().unwrap_or_default();
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(v6) = host.strip_prefix('[') {
        v6.split(']').next().unwrap_or_default()
    } else {
        host.split(':').next().unwrap_or_default()
    };
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
        return false;
    }
    host.parse::<IpAddr>().map_or(true, |ip| !ip.is_loopback())
}

#[cfg(test)]
#[path = "netcheck_tests.rs"]
mod tests;

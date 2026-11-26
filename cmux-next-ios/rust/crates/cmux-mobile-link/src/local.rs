//! Nearby links with no internet (ultra-connectivity P7).
//!
//! A Mac advertises its local hub (`local_hub.rs`) over mDNS / Bonjour as
//! [`SERVICE_TYPE`]; a phone on the same LAN, or beside it over AWDL, finds it
//! and signals the WireGuard dial through the hub instead of the Worker: no
//! cloud round trip, and a link even where the network has no route out.
//!
//! The ad carries no secret: the Mac's device id (which Mac this is), the
//! version, and [`key_tag`], a short hash of the Mac's identity key that lets
//! a phone skip an ad whose key does not match the Mac it paired with. Who
//! the peers are is still proven on the link itself: the `auth` channel
//! (PROTOCOL.md "Pairing on every link") with the paired keys.
//!
//! Everything here is policy (what an ad says, which address to try, how
//! long an ad lives); the mDNS socket work is the platform's: `mdns-sd` on the
//! Mac and Linux (cmux-mobile-host `mdns.rs`), NWBrowser on iOS.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use cmux_braid_carrier::{Carrier, CarrierKind, Endpoint, OpenFuture};
use cmux_braid_path::RacePolicy;

use crate::signaling::{SignalingClient, SignalingError};

/// The Bonjour service type: the advertised port is the hub's TCP port.
pub const SERVICE_TYPE: &str = "_cmux-link._tcp.local.";
/// The same type as NWBrowser names it (no `.local.`).
pub const BONJOUR_TYPE: &str = "_cmux-link._tcp";
/// The ad's format version (`v=`), in lockstep with every reader:
///
/// - a key this side does not know is ignored, so a new key (a capability, a
///   hint) is added with no bump and older phones read the rest of the ad;
/// - an ad with no `v` is read as version 1 (the first ads);
/// - a bump means an older reader can no longer use the ad: it skips it
///   ([`LocalAd::from_txt`]) and dials through the Worker as before, so a
///   newer Mac that must stay reachable to older phones keeps advertising a
///   version-1 instance beside its new one;
/// - a `v` that is not a number is skipped like an unknown version.
///
/// Tests: `lockstep_*` here and in `local_hub.rs`.
pub const AD_VERSION: u32 = 1;
/// The local hub's wire version, in lockstep both ways: the hub's `hello`
/// carries it as `hubVersion` and a phone's upgrade URL as
/// `&hubVersion=` ([`HUB_VERSION_PARAM`]). Either side missing the field is
/// version 0, the hub before it was sent, and the two speak the subset of
/// the Worker's signaling wire both have (PROTOCOL.md "Signaling
/// WebSocket"): unknown fields are kept and forwarded, unknown message
/// types ignored. Bump it when the hub learns something a phone may rely on
/// (and gate that on the phone's version), never to drop the old subset.
///
/// - 1: `hello`, `signal` forwarding by `to`, text `ping` / `pong`.
pub const HUB_VERSION: u32 = 1;
/// The upgrade URL's query key for [`HUB_VERSION`].
pub const HUB_VERSION_PARAM: &str = "hubVersion";
/// The team segment of a hub URL: a hub serves one Mac, not a team.
pub const LOCAL_TEAM: &str = "local";
/// The bearer a phone presents to a hub: the hub admits by device id and
/// pairing, not by this token.
pub const PHONE_TOKEN: &str = "local";
/// The `fromUserId` a hub stamps on what it forwards: the hub admitted the
/// sender itself (`local_hub.rs` `Admit`).
pub const LOCAL_USER: &str = "local";
/// An ad unseen for this long is gone (mDNS records live 120 s by default).
pub const AD_TTL: Duration = Duration::from_secs(120);
/// How long one hub address may take to open before the next is tried
/// beside it (Happy Eyeballs, RFC 8305's 250 ms).
pub const ATTEMPT_DELAY: Duration = Duration::from_millis(250);
/// The whole hub dial, every address: a LAN answers in milliseconds.
pub const HUB_CONNECT_WAIT: Duration = Duration::from_secs(3);

const TAG_DOMAIN: &[u8] = b"cmux-link-local-v1";

/// The ad's short key tag: the first 8 bytes of
/// SHA-256("cmux-link-local-v1" ‖ identity public key), hex. Not a secret and
/// not a proof: a filter, so a phone never dials a Mac it did not pair with.
pub fn key_tag(identity_public_key: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(TAG_DOMAIN);
    hash.update(identity_public_key);
    hash.finalize()[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// What a Mac's ad says (its TXT record).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalAd {
    /// The Mac's device id: the `to` of signals sent through its hub.
    pub device_id: String,
    pub version: u32,
    /// [`key_tag`] of the Mac's identity key; `None` from an unpaired hostd.
    pub tag: Option<String>,
}

impl LocalAd {
    /// The TXT record's key=value pairs.
    pub fn txt(&self) -> Vec<(String, String)> {
        let mut txt =
            vec![("id".to_owned(), self.device_id.clone()), ("v".to_owned(), self.version.to_string())];
        if let Some(tag) = &self.tag {
            txt.push(("k".to_owned(), tag.clone()));
        }
        txt
    }

    /// Read an ad from TXT pairs; `None` without an id, or of a version this
    /// side cannot read ([`AD_VERSION`]: unknown keys are ignored, a missing
    /// `v` is 1, any other `v` is skipped).
    pub fn from_txt<'a>(pairs: impl IntoIterator<Item = (&'a str, &'a str)>) -> Option<Self> {
        let (mut id, mut version, mut tag) = (None, Some(AD_VERSION), None);
        for (key, value) in pairs {
            match key {
                "id" if !value.is_empty() => id = Some(value.to_owned()),
                "v" => version = value.parse().ok(),
                "k" if !value.is_empty() => tag = Some(value.to_owned()),
                _ => {}
            }
        }
        let version = version.filter(|v| *v == AD_VERSION)?;
        Some(Self { device_id: id?, version, tag })
    }

    /// Whether this ad is the Mac the phone wants: its id, and its key tag
    /// when both sides know one.
    pub fn matches(&self, device_id: &str, tag: Option<&str>) -> bool {
        self.device_id == device_id
            && match (self.tag.as_deref(), tag) {
                (Some(ad), Some(want)) => ad == want,
                _ => true,
            }
    }
}

/// How good an address is for a hub dial: lower first. A private IPv4
/// address is the LAN itself; a link-local IPv6 address (AWDL's only kind,
/// and every LAN's) works with no router at all but needs its scope; a
/// global address may route out and back; loopback only on the same host.
pub fn rank(address: &SocketAddr) -> u8 {
    match address.ip() {
        IpAddr::V4(ip) if ip.is_private() => 0,
        IpAddr::V6(ip) if ip.is_unique_local() => 1,
        IpAddr::V6(ip) if ip.is_unicast_link_local() => 2,
        IpAddr::V4(ip) if ip.is_link_local() => 3,
        IpAddr::V4(ip) if ip.is_loopback() => 5,
        IpAddr::V6(ip) if ip.is_loopback() => 5,
        _ => 4,
    }
}

/// `addresses`, best first ([`rank`]), without duplicates.
pub fn ordered(mut addresses: Vec<SocketAddr>) -> Vec<SocketAddr> {
    addresses.sort_by_key(|a| (rank(a), a.is_ipv6()));
    addresses.dedup();
    addresses
}

/// A hub's URL for `address` (`ws://[v6%scope]:port`).
pub fn hub_url(address: &SocketAddr) -> String {
    match address {
        SocketAddr::V4(a) => format!("ws://{a}"),
        // tungstenite parses a zone in the host ([fe80::1%25en0]); a
        // numeric scope id is what both the platform and a URL accept.
        SocketAddr::V6(a) if a.scope_id() != 0 => {
            format!("ws://[{}%25{}]:{}", a.ip(), a.scope_id(), a.port())
        }
        SocketAddr::V6(a) => format!("ws://[{}]:{}", a.ip(), a.port()),
    }
}

/// One Mac's hub as the browser last saw it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalPeer {
    pub ad: LocalAd,
    /// Best first.
    pub addresses: Vec<SocketAddr>,
    pub seen: Instant,
}

/// The Macs nearby: what the platform browser found, by device id, each ad
/// expiring [`AD_TTL`] after it was last seen.
#[derive(Debug, Default)]
pub struct LocalPeers {
    peers: HashMap<String, LocalPeer>,
}

impl LocalPeers {
    /// An ad resolved (or refreshed) to `addresses`.
    pub fn observe(&mut self, ad: LocalAd, addresses: Vec<SocketAddr>, now: Instant) {
        let addresses = ordered(addresses);
        if addresses.is_empty() {
            return;
        }
        self.peers.insert(ad.device_id.clone(), LocalPeer { ad, addresses, seen: now });
    }

    /// The browser saw the ad go (a goodbye packet, or the service removed).
    pub fn remove(&mut self, device_id: &str) {
        self.peers.remove(device_id);
    }

    /// Mac `device_id`'s hub addresses, best first, if its ad is live and
    /// matches `tag`.
    pub fn addresses(&self, device_id: &str, tag: Option<&str>, now: Instant) -> Vec<SocketAddr> {
        self.peers
            .get(device_id)
            .filter(|peer| {
                now.saturating_duration_since(peer.seen) < AD_TTL && peer.ad.matches(device_id, tag)
            })
            .map(|peer| peer.addresses.clone())
            .unwrap_or_default()
    }

    /// Forget every ad (the phone changed network: what it saw is not on the new one; the browser
    /// re-reports the live ones).
    pub fn clear(&mut self) {
        self.peers.clear();
    }

    /// Every live peer.
    pub fn live(&self, now: Instant) -> Vec<LocalPeer> {
        self.peers.values().filter(|p| now.saturating_duration_since(p.seen) < AD_TTL).cloned().collect()
    }
}

/// The Mac's local hub as a braid carrier ([`Carrier`]): opening a [`CarrierKind::LocalHub`]
/// endpoint (one hub address, `host:port`, a link-local one with its `%scope`) opens a signaling
/// socket to that hub as `device_id`. No internet is needed.
pub struct LocalHubRung<'a> {
    pub device_id: &'a str,
}

/// A hub address as a [`CarrierKind::LocalHub`] endpoint.
pub fn hub_endpoint(address: &SocketAddr) -> Endpoint {
    Endpoint {
        kind: CarrierKind::LocalHub,
        address: address.to_string(),
        host: address.ip().to_string(),
        login: None,
    }
}

impl Carrier for LocalHubRung<'_> {
    type Link = SignalingClient;

    fn kind(&self) -> CarrierKind {
        CarrierKind::LocalHub
    }

    fn open<'b>(&'b self, endpoint: &'b Endpoint) -> OpenFuture<'b, SignalingClient> {
        Box::pin(async move {
            if endpoint.kind != CarrierKind::LocalHub {
                return Err(std::io::Error::other("the endpoint is another carrier's"));
            }
            let address: SocketAddr = endpoint.address.parse().map_err(|_| {
                std::io::Error::other(SignalingError::BadUrl(format!(
                    "not a hub address: {}",
                    endpoint.address
                )))
            })?;
            SignalingClient::connect_local(&hub_url(&address), PHONE_TOKEN, self.device_id)
                .await
                .map_err(std::io::Error::other)
        })
    }
}

/// A carrier or race error back as the hub's own: the [`SignalingError`] an attempt failed
/// with, else a connect failure with the error's text.
fn signaling_error(error: std::io::Error) -> SignalingError {
    match error.downcast::<SignalingError>() {
        Ok(error) => error,
        Err(error) => SignalingError::Connect(error.to_string()),
    }
}

/// How [`connect_hub`] races a Mac's hub addresses: each once, best first, the next
/// [`ATTEMPT_DELAY`] after the last or at once when one fails (Happy Eyeballs).
pub fn hub_race_policy(addresses: usize) -> RacePolicy {
    RacePolicy {
        stagger: ATTEMPT_DELAY,
        attempt_timeout: HUB_CONNECT_WAIT,
        last_attempt_timeout: HUB_CONNECT_WAIT,
        max_in_flight: addresses.max(1),
        max_attempts: addresses.max(1),
    }
}

/// Open a signaling socket to a Mac's hub, racing `addresses` (best first,
/// each [`ATTEMPT_DELAY`] after the last, as Happy Eyeballs does) on
/// [`cmux_braid_path::race`] through [`LocalHubRung`]: the first to open wins.
/// `dial::connect` on the result reaches the Mac with no Worker.
pub async fn connect_hub(
    addresses: &[SocketAddr],
    device_id: &str,
) -> Result<SignalingClient, SignalingError> {
    if addresses.is_empty() {
        return Err(SignalingError::Connect("no local address for this Mac".into()));
    }
    let rung = LocalHubRung { device_id };
    let endpoints: Vec<Endpoint> = addresses.iter().map(hub_endpoint).collect();
    let race = cmux_braid_path::race(&endpoints, hub_race_policy(endpoints.len()), |endpoint| {
        let rung = &rung;
        async move { rung.open(&endpoint).await }
    });
    match tokio::time::timeout(HUB_CONNECT_WAIT, race).await {
        Ok(Ok(won)) => Ok(won.value),
        Ok(Err(error)) => Err(signaling_error(error)),
        Err(_) => Err(SignalingError::Connect("no hub answered in time".into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hub_is_a_braid_carrier_on_the_direct_rung() {
        let rung = LocalHubRung { device_id: "phone" };
        assert_eq!(rung.kind(), CarrierKind::LocalHub);
        assert!(!rung.kind().needs_internet());
        // A link-local address keeps its scope through the endpoint.
        let scoped: SocketAddr = "[fe80::1%3]:50000".parse().unwrap();
        let endpoint = hub_endpoint(&scoped);
        assert_eq!(endpoint.kind, CarrierKind::LocalHub);
        assert_eq!(endpoint.address.parse::<SocketAddr>().unwrap(), scoped);
        assert_eq!(endpoint.port(), Some(50000));
        let policy = hub_race_policy(3);
        assert_eq!((policy.stagger, policy.max_attempts, policy.max_in_flight), (ATTEMPT_DELAY, 3, 3));
    }

    #[test]
    fn a_hub_failure_survives_the_carrier_error() {
        let io = std::io::Error::other(SignalingError::Unauthorized);
        assert!(matches!(signaling_error(io), SignalingError::Unauthorized));
        let timed_out = std::io::Error::new(std::io::ErrorKind::TimedOut, "no answer within 3000 ms");
        assert!(matches!(signaling_error(timed_out), SignalingError::Connect(m) if m.contains("3000")));
    }

    #[tokio::test]
    async fn the_hub_rung_opens_only_hub_endpoints() {
        let rung = LocalHubRung { device_id: "phone" };
        let mut endpoint = hub_endpoint(&"127.0.0.1:9".parse().unwrap());
        endpoint.kind = CarrierKind::WssRelay;
        let error = rung.open(&endpoint).await.err().unwrap();
        assert!(error.to_string().contains("another carrier"), "{error}");
        let garbage = Endpoint {
            kind: CarrierKind::LocalHub,
            address: "nope".into(),
            host: "nope".into(),
            login: None,
        };
        let error = rung.open(&garbage).await.err().unwrap();
        assert!(matches!(signaling_error(error), SignalingError::BadUrl(_)));
    }

    #[test]
    fn txt_round_trips_and_carries_no_secret() {
        let ad = LocalAd { device_id: "mac-1".into(), version: AD_VERSION, tag: Some(key_tag(b"pub")) };
        let txt = ad.txt();
        assert_eq!(txt.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), ["id", "v", "k"]);
        assert_eq!(txt[2].1.len(), 16);
        let back = LocalAd::from_txt(txt.iter().map(|(k, v)| (k.as_str(), v.as_str())));
        assert_eq!(back, Some(ad));
    }

    #[test]
    fn other_versions_and_missing_ids_are_skipped() {
        assert_eq!(LocalAd::from_txt([("id", "m"), ("v", "2")]), None);
        assert_eq!(LocalAd::from_txt([("v", "1")]), None);
        assert!(LocalAd::from_txt([("id", "m")]).is_some());
    }

    /// Lockstep (P7 13f): a v=2 ad (a newer Mac) against this v=1 browser is
    /// skipped, never misread, and never reaches [`LocalPeers`]; a `v` that is
    /// not a number is skipped too.
    #[test]
    fn lockstep_newer_ad_version_is_skipped_by_this_browser() {
        let tag = key_tag(b"pub");
        let newer = [("id", "mac-1"), ("v", "2"), ("k", tag.as_str()), ("h", "2")];
        assert_eq!(LocalAd::from_txt(newer), None);
        assert_eq!(LocalAd::from_txt([("id", "mac-1"), ("v", "two")]), None);
        assert_eq!(LocalAd::from_txt([("id", "mac-1"), ("v", "")]), None);
        assert_eq!(LocalAd::from_txt([("id", "mac-1"), ("v", "0")]), None);
        // What a browse does with what it heard: only the readable ad is a peer.
        let mut peers = LocalPeers::default();
        let now = Instant::now();
        for txt in [vec![("id", "mac-2"), ("v", "2")], vec![("id", "mac-1"), ("v", "1")]] {
            if let Some(ad) = LocalAd::from_txt(txt) {
                peers.observe(ad, vec!["10.0.0.2:9".parse().unwrap()], now);
            }
        }
        assert!(peers.addresses("mac-2", None, now).is_empty());
        assert_eq!(peers.addresses("mac-1", None, now).len(), 1);
    }

    /// Lockstep (P7 13f): a v=1 ad from a newer Mac with keys this side does
    /// not know reads as the ad it knows; an ad with no `v` (the first ads)
    /// is version 1; and this side's ad is what a v=1 reader expects.
    #[test]
    fn lockstep_unknown_keys_and_missing_version_read_as_v1() {
        let tag = key_tag(b"pub");
        let with_more = [("id", "mac-1"), ("future", "x"), ("v", "1"), ("k", tag.as_str()), ("flag", "")];
        let ad = LocalAd::from_txt(with_more).unwrap();
        assert_eq!(ad, LocalAd { device_id: "mac-1".into(), version: 1, tag: Some(tag.clone()) });
        assert_eq!(LocalAd::from_txt([("id", "mac-1")]).unwrap().version, AD_VERSION);
        let ours = LocalAd { device_id: "mac-1".into(), version: AD_VERSION, tag: Some(tag) }.txt();
        assert!(ours.contains(&("v".to_owned(), "1".to_owned())), "{ours:?}");
    }

    #[test]
    fn tag_filters_only_when_both_sides_know_one() {
        let ad = LocalAd { device_id: "m".into(), version: 1, tag: Some(key_tag(b"a")) };
        assert!(ad.matches("m", Some(&key_tag(b"a"))));
        assert!(!ad.matches("m", Some(&key_tag(b"b"))));
        assert!(ad.matches("m", None));
        assert!(!ad.matches("n", None));
    }

    #[test]
    fn lan_addresses_come_first() {
        let order = ordered(vec![
            "[fe80::1%4]:7".parse().unwrap(),
            "8.8.8.8:7".parse().unwrap(),
            "192.168.1.4:7".parse().unwrap(),
            "127.0.0.1:7".parse().unwrap(),
        ]);
        let want = |s: &str| s.parse::<SocketAddr>().unwrap();
        assert_eq!(order[0], want("192.168.1.4:7"));
        assert_eq!(order[1], want("[fe80::1%4]:7"));
        assert_eq!(order[3], want("127.0.0.1:7"));
        assert_eq!(hub_url(&order[1]), "ws://[fe80::1%254]:7");
    }

    #[test]
    fn ads_expire() {
        let mut peers = LocalPeers::default();
        let t0 = Instant::now();
        let ad = LocalAd { device_id: "m".into(), version: 1, tag: None };
        peers.observe(ad, vec!["10.0.0.2:9".parse().unwrap()], t0);
        assert_eq!(peers.addresses("m", None, t0).len(), 1);
        assert!(peers.addresses("m", None, t0 + AD_TTL).is_empty());
        peers.remove("m");
        assert!(peers.live(t0).is_empty());
    }
}

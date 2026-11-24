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

use crate::signaling::{SignalingClient, SignalingError};

/// The Bonjour service type: the advertised port is the hub's TCP port.
pub const SERVICE_TYPE: &str = "_cmux-link._tcp.local.";
/// The same type as NWBrowser names it (no `.local.`).
pub const BONJOUR_TYPE: &str = "_cmux-link._tcp";
/// The ad's format version (`v=`).
pub const AD_VERSION: u32 = 1;
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

    /// Read an ad from TXT pairs; `None` without an id or of another version.
    pub fn from_txt<'a>(pairs: impl IntoIterator<Item = (&'a str, &'a str)>) -> Option<Self> {
        let (mut id, mut version, mut tag) = (None, None, None);
        for (key, value) in pairs {
            match key {
                "id" if !value.is_empty() => id = Some(value.to_owned()),
                "v" => version = value.parse().ok(),
                "k" if !value.is_empty() => tag = Some(value.to_owned()),
                _ => {}
            }
        }
        let version = version.unwrap_or(AD_VERSION);
        (version == AD_VERSION).then_some(Self { device_id: id?, version, tag })
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

    /// Every live peer.
    pub fn live(&self, now: Instant) -> Vec<LocalPeer> {
        self.peers.values().filter(|p| now.saturating_duration_since(p.seen) < AD_TTL).cloned().collect()
    }
}

/// Open a signaling socket to a Mac's hub, racing `addresses` (best first,
/// each [`ATTEMPT_DELAY`] after the last, as Happy Eyeballs does): the first
/// to open wins. `dial::connect` on the result reaches the Mac with no Worker.
pub async fn connect_hub(
    addresses: &[SocketAddr],
    device_id: &str,
) -> Result<SignalingClient, SignalingError> {
    use futures_util::StreamExt;
    use futures_util::stream::FuturesUnordered;
    if addresses.is_empty() {
        return Err(SignalingError::Connect("no local address for this Mac".into()));
    }
    let race = async {
        let mut attempts = FuturesUnordered::new();
        let mut pending = addresses.iter();
        let mut last_error = None;
        loop {
            if let Some(address) = pending.next() {
                let url = hub_url(address);
                let device = device_id.to_owned();
                attempts
                    .push(async move { SignalingClient::connect_local(&url, PHONE_TOKEN, &device).await });
            } else if attempts.is_empty() {
                return Err(last_error.unwrap_or_else(|| SignalingError::Connect("no hub answered".into())));
            }
            let next = if pending.len() > 0 {
                match tokio::time::timeout(ATTEMPT_DELAY, attempts.next()).await {
                    Ok(next) => next,
                    Err(_) => continue,
                }
            } else {
                attempts.next().await
            };
            match next {
                Some(Ok(client)) => return Ok(client),
                Some(Err(error)) => last_error = Some(error),
                None => {}
            }
        }
    };
    tokio::time::timeout(HUB_CONNECT_WAIT, race)
        .await
        .unwrap_or_else(|_| Err(SignalingError::Connect("no hub answered in time".into())))
}

#[cfg(test)]
mod tests {
    use super::*;

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

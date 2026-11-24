//! Nearby links with no internet (ultra-connectivity P7), the phone's side.
//!
//! The platform browser (Swift `NWBrowser` for `_cmux-link._tcp`, over Wi-Fi and AWDL) only reports
//! what it sees: an instance name, its TXT pairs and the addresses it resolved to. Everything
//! else is here: whether the ad is a cmux ad and the Mac the phone paired with, which addresses
//! to try and in what order ([`cmux_mobile_link::local`]), and when a dial goes through the Mac's
//! local hub as well as the Worker (`dial` in lib.rs races [`dial_local`] with the service dial).

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use cmux_mobile_link::Timeline;
use cmux_mobile_link::local::{self, LocalAd, LocalPeers};

use crate::{CmuxMobileError, ConnectRequest, LinkObserver, SocketKey, Transport, WarmSocket};

/// One TXT pair of a discovered ad (`id`, `v`, `k`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LocalTxt {
    pub key: String,
    pub value: String,
}

/// One resolved address of a discovered ad, as the platform prints it: `192.168.1.5`,
/// `fe80::1%en0` or `fe80::1%awdl0` (a scope is an interface name or its index).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LocalEndpoint {
    pub host: String,
    pub port: u16,
}

#[derive(Default)]
struct State {
    peers: LocalPeers,
    /// Service instance name to the Mac's device id, so a removed service drops its Mac.
    instances: HashMap<String, String>,
    /// The key tag of each paired Mac's identity key, by device id.
    tags: HashMap<String, String>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with_state<T>(f: impl FnOnce(&mut State) -> T) -> T {
    f(STATE.lock().unwrap_or_else(PoisonError::into_inner).get_or_insert_with(State::default))
}

/// A scope written as an interface name or index, as its number (0: none).
fn scope_id(scope: &str) -> Option<u32> {
    if let Ok(index) = scope.parse::<u32>() {
        return Some(index);
    }
    #[cfg(unix)]
    {
        let name = std::ffi::CString::new(scope).ok()?;
        // SAFETY: `name` is a valid NUL-terminated string for the call.
        let index = unsafe { libc::if_nametoindex(name.as_ptr()) };
        return (index != 0).then_some(index);
    }
    #[cfg(not(unix))]
    None
}

/// `host` and `port` as a socket address; `None` for a name or a scope that does not resolve.
pub fn parse_endpoint(host: &str, port: u16) -> Option<SocketAddr> {
    let host = host.trim().trim_start_matches('[').trim_end_matches(']');
    let (ip, scope) = match host.split_once('%') {
        Some((ip, scope)) => (ip, Some(scope)),
        None => (host, None),
    };
    if let Ok(v4) = ip.parse::<Ipv4Addr>() {
        return Some(SocketAddr::new(IpAddr::V4(v4), port));
    }
    let v6 = ip.parse::<Ipv6Addr>().ok()?;
    let scope = match scope {
        Some(scope) => scope_id(scope)?,
        None => 0,
    };
    // A link-local address with no scope cannot be dialed.
    if scope == 0 && v6.is_unicast_link_local() {
        return None;
    }
    Some(SocketAddr::V6(SocketAddrV6::new(v6, port, 0, scope)))
}

fn ad_of(txt: &[LocalTxt]) -> Option<LocalAd> {
    LocalAd::from_txt(txt.iter().map(|pair| (pair.key.as_str(), pair.value.as_str())))
}

/// The browser resolved (or refreshed) service `instance`. Returns whether it is a cmux ad with an
/// address the phone can dial (anything else is ignored).
#[uniffi::export]
pub fn local_link_observe(instance: String, txt: Vec<LocalTxt>, endpoints: Vec<LocalEndpoint>) -> bool {
    let Some(ad) = ad_of(&txt) else { return false };
    let addresses: Vec<SocketAddr> =
        endpoints.iter().filter_map(|endpoint| parse_endpoint(&endpoint.host, endpoint.port)).collect();
    if addresses.is_empty() {
        return false;
    }
    with_state(|state| {
        // The instance now names another Mac (a renamed or reused name): drop the old one.
        if let Some(old) = state.instances.insert(instance, ad.device_id.clone())
            && old != ad.device_id
        {
            state.peers.remove(&old);
        }
        state.peers.observe(ad, addresses, Instant::now());
    });
    true
}

/// Whether the browser should resolve service `instance` (ad TXT `txt`) now. Resolving opens a
/// connection to the Mac's hub, so it is worth it only for the ad of a Mac this phone paired with,
/// carrying the tag of the key it pinned, and not again while that instance's addresses are still
/// live (a TXT refresh of the same ad changes nothing). Another phone's Mac is never touched.
#[uniffi::export]
pub fn local_link_wants_resolve(instance: String, txt: Vec<LocalTxt>) -> bool {
    let Some(ad) = ad_of(&txt) else { return false };
    let mac = ad.device_id.to_lowercase();
    with_state(|state| {
        let Some(tag) = state.tags.get(&mac) else { return false };
        if !ad.matches(&ad.device_id, Some(tag)) {
            return false;
        }
        let known = state.instances.get(&instance).is_some_and(|id| id.eq_ignore_ascii_case(&ad.device_id));
        !(known && !state.peers.addresses(&ad.device_id, Some(tag), Instant::now()).is_empty())
    })
}

/// The browser saw service `instance` go away.
#[uniffi::export]
pub fn local_link_remove(instance: String) {
    with_state(|state| {
        if let Some(device_id) = state.instances.remove(&instance) {
            state.peers.remove(&device_id);
        }
    });
}

/// The phone paired with Mac `mac_device_id`, whose identity public key is `identity_public_key`
/// (nil: forget the key). Its ad is then trusted only with the key tag of that key. The key is the
/// bytes the Mac hashes for its tag: its X9.63 identity key as lowercase hex (`MacPins`), so a
/// phone hands over exactly what it pinned. Device ids compare without case, as the pins do.
#[uniffi::export]
pub fn local_link_pair(mac_device_id: String, identity_public_key: Option<Vec<u8>>) {
    let mac = mac_device_id.to_lowercase();
    with_state(|state| match identity_public_key {
        Some(key) => {
            state.tags.insert(mac, local::key_tag(&key.to_ascii_lowercase()));
        }
        None => {
            state.tags.remove(&mac);
        }
    });
}

/// Whether the ad with TXT `txt` is Mac `mac_device_id` (and the key `identity_public_key`, when
/// both the ad and the caller carry one). For a browser that wants to filter before it resolves.
#[uniffi::export]
pub fn local_link_matches(
    txt: Vec<LocalTxt>,
    mac_device_id: String,
    identity_public_key: Option<Vec<u8>>,
) -> bool {
    let tag = identity_public_key.map(|key| local::key_tag(&key));
    ad_of(&txt).is_some_and(|ad| ad.matches(&mac_device_id, tag.as_deref()))
}

/// The hub addresses of Mac `mac_device_id`, best first, while its ad is live and carries the tag
/// of the key it was paired with. Empty: not nearby. A Mac with no pinned key is never nearby: an
/// ad naming its id with no key to check it against could be anybody's.
pub fn nearby(mac_device_id: &str) -> Vec<SocketAddr> {
    with_state(|state| {
        let Some(tag) = state.tags.get(&mac_device_id.to_lowercase()) else { return Vec::new() };
        state.peers.addresses(mac_device_id, Some(tag), Instant::now())
    })
}

/// Whether Mac `mac_device_id` is nearby now (its ad is live and matches).
#[uniffi::export]
pub fn local_link_nearby(mac_device_id: String) -> bool {
    !nearby(&mac_device_id).is_empty()
}

/// Dial through the Mac's hub at `addresses`: no Worker, no ICE servers (host candidates are the
/// whole path), no internet needed.
pub async fn dial_hub(
    request: &ConnectRequest,
    addresses: &[SocketAddr],
    timeline: &Timeline,
) -> Result<(cmux_mobile_link::Connected, Arc<WarmSocket>), CmuxMobileError> {
    let client = local::connect_hub(addresses, &request.device_id).await?;
    timeline.mark("local_hub_open");
    let socket = Arc::new(WarmSocket {
        key: SocketKey {
            base_url: String::new(),
            team_id: local::LOCAL_TEAM.to_owned(),
            device_id: request.device_id.clone(),
            build_space: None,
        },
        client,
        local: true,
    });
    let options = crate::dial_options(request, Vec::new(), timeline);
    match crate::dial_on(&socket, request, &options, false).await {
        Ok(connected) => Ok((connected, socket)),
        Err(crate::Attempt::Failed(error)) => Err(error.into()),
        Err(crate::Attempt::Stale) => unreachable!("only a reused socket is probed"),
    }
}

/// The longest a hub dial (hub socket and link) may take: a LAN answers in tens of ms (p95 115 ms
/// in netlab), so a hub that has not linked by then is not on this network. With no route out it
/// is the only path, so the bound leaves a slow Wi-Fi room.
pub const LOCAL_DIAL_BOUND: std::time::Duration = std::time::Duration::from_secs(2);

/// One of `dial`'s two racers: when Mac `request.mac_device_id` is nearby, dial it through its hub. `None`
/// when it is not nearby or the hub dial failed (then the service dial it races with decides).
pub async fn dial_local(
    request: &ConnectRequest,
    timeline: &Timeline,
) -> Option<(cmux_mobile_link::Connected, Arc<WarmSocket>)> {
    // A simulated distant network (relay only, UDP blocked) is a test of the paths this one skips.
    if request.relay_only || request.block_udp {
        return None;
    }
    if request.device_id.trim().is_empty() || request.mac_device_id.trim().is_empty() {
        return None;
    }
    let addresses = nearby(&request.mac_device_id);
    if addresses.is_empty() {
        return None;
    }
    let bounded = tokio::time::timeout(LOCAL_DIAL_BOUND, dial_hub(request, &addresses, timeline));
    match bounded.await.unwrap_or_else(|_| Err(CmuxMobileError::Timeout)) {
        Ok(ok) => {
            timeline.mark("local_link");
            Some(ok)
        }
        Err(error) => {
            tracing::info!(%error, "local hub dial failed; using the service");
            timeline.mark("local_failed");
            None
        }
    }
}

/// Dial Mac `mac_device_id` from this phone (`device_id`) through its local hub at `endpoints`
/// (what the browser resolved; best first is decided here), with no service involved. The
/// everyday dial (`connect`) already takes this path by itself when the Mac is nearby; this is the
/// explicit form, for a caller that holds the addresses.
#[uniffi::export]
pub async fn connect_local(
    device_id: String,
    mac_device_id: String,
    endpoints: Vec<LocalEndpoint>,
    transport: Transport,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<crate::LinkHandle>, CmuxMobileError> {
    let addresses = local::ordered(
        endpoints.iter().filter_map(|endpoint| parse_endpoint(&endpoint.host, endpoint.port)).collect(),
    );
    let request = ConnectRequest {
        base_url: String::new(),
        token: String::new(),
        team_id: local::LOCAL_TEAM.to_owned(),
        device_id,
        mac_device_id,
        transport,
        include_loopback: false,
        relay_only: false,
        force_relay: false,
        block_udp: false,
        video_lane: true,
        webrtc_media: false,
        ultra: cmux_mobile_link::UltraSetting::parse("auto"),
    };
    connect_local_inner(request, addresses, observer).await
}

/// `connect_local` for a prepared request (tests set `include_loopback`).
#[doc(hidden)]
pub async fn connect_local_inner(
    request: ConnectRequest,
    addresses: Vec<SocketAddr>,
    observer: Option<Arc<dyn LinkObserver>>,
) -> Result<Arc<crate::LinkHandle>, CmuxMobileError> {
    crate::on_runtime(async move {
        let timeline = Timeline::new();
        let (connected, socket) = dial_hub(&request, &addresses, &timeline).await?;
        crate::finish_link(&crate::WarmPool::shared().0, &request, connected, socket, timeline, observer)
            .await
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn txt(pairs: &[(&str, &str)]) -> Vec<LocalTxt> {
        pairs.iter().map(|(k, v)| LocalTxt { key: (*k).into(), value: (*v).into() }).collect()
    }

    /// The ads and pins are one process-wide table: the tests that read or change it take turns.
    static TABLE: Mutex<()> = Mutex::new(());
    fn table() -> std::sync::MutexGuard<'static, ()> {
        TABLE.lock().unwrap_or_else(PoisonError::into_inner)
    }

    #[test]
    fn endpoints_parse_with_and_without_scope() {
        assert_eq!(parse_endpoint("192.168.1.5", 7).unwrap().to_string(), "192.168.1.5:7");
        assert_eq!(parse_endpoint("fe80::1%4", 7).unwrap().to_string(), "[fe80::1%4]:7");
        assert_eq!(parse_endpoint("[fd00::2]", 7).unwrap().to_string(), "[fd00::2]:7");
        assert!(parse_endpoint("fe80::1", 7).is_none(), "link-local needs its scope");
        assert!(parse_endpoint("fe80::1%nosuchif0", 7).is_none());
        assert!(parse_endpoint("mac.local", 7).is_none());
    }

    #[test]
    fn a_found_ad_is_nearby_only_for_its_mac_and_key() {
        let _table = table();
        let tag = local::key_tag(b"mac-key");
        let ad = txt(&[("id", "mac-A"), ("v", "1"), ("k", &tag)]);
        let here = vec![LocalEndpoint { host: "10.0.0.9".into(), port: 4000 }];
        assert!(!local_link_observe("junk".into(), txt(&[("x", "y")]), here.clone()));
        assert!(!local_link_observe("noaddr".into(), ad.clone(), vec![]));
        assert!(local_link_observe("Mac A".into(), ad.clone(), here));
        // Not paired yet: an ad naming the Mac with nothing to check it against is not dialed.
        assert!(!local_link_nearby("mac-A".into()));
        local_link_pair("mac-A".into(), Some(b"mac-key".to_vec()));
        assert!(local_link_nearby("mac-A".into()));
        assert!(!local_link_nearby("mac-B".into()));
        // Paired with another key: the ad is somebody else's.
        local_link_pair("mac-A".into(), Some(b"other-key".to_vec()));
        assert!(!local_link_nearby("mac-A".into()));
        // The phone hands over its pin as it stored it (MacPins: lowercase id, lowercase hex);
        // case on either side still names the same Mac and key.
        local_link_pair("MAC-a".into(), Some(b"MAC-KEY".to_vec()));
        assert!(local_link_nearby("mac-A".into()));
        local_link_pair("mac-A".into(), Some(b"mac-key".to_vec()));
        assert!(local_link_nearby("mac-A".into()));
        assert!(local_link_matches(ad.clone(), "mac-A".into(), Some(b"mac-key".to_vec())));
        assert!(!local_link_matches(ad, "mac-A".into(), Some(b"other-key".to_vec())));
        local_link_remove("Mac A".into());
        assert!(!local_link_nearby("mac-A".into()));
        local_link_pair("mac-A".into(), None);
    }

    #[test]
    fn only_a_paired_macs_ad_is_resolved_and_only_once_while_live() {
        let _table = table();
        let tag = local::key_tag(b"mac-key");
        let ad = txt(&[("id", "mac-R"), ("v", "1"), ("k", &tag)]);
        let here = vec![LocalEndpoint { host: "10.0.0.7".into(), port: 4000 }];
        // Not paired: somebody else's Mac, never connected to.
        assert!(!local_link_wants_resolve("Mac R".into(), ad.clone()));
        assert!(!local_link_wants_resolve("junk".into(), txt(&[("x", "y")])));
        local_link_pair("mac-R".into(), Some(b"other-key".to_vec()));
        assert!(!local_link_wants_resolve("Mac R".into(), ad.clone()), "an ad with another key's tag");
        local_link_pair("MAC-R".into(), Some(b"mac-key".to_vec()));
        assert!(local_link_wants_resolve("Mac R".into(), ad.clone()));
        assert!(local_link_observe("Mac R".into(), ad.clone(), here));
        // A TXT refresh of the same live ad: nothing to resolve.
        assert!(!local_link_wants_resolve("Mac R".into(), ad.clone()));
        local_link_remove("Mac R".into());
        assert!(local_link_wants_resolve("Mac R".into(), ad));
        local_link_pair("mac-R".into(), None);
    }
}

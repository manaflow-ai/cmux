//! NAT port mapping, as the WireGuard answer side sees it (PROTOCOL.md
//! "Mapped endpoints"): a Mac asks its home router for a mapped UDP port for
//! a session's socket (PCP, NAT-PMP or UPnP-IGD; `cmux-mobile-host`
//! `portmap`), and offers the mapped public address to the phone as one more
//! endpoint, labeled `mapped`. A phone behind a NAT that maps per destination
//! (symmetric NAT, a carrier's CGNAT) can then reach the Mac directly, where
//! hole punching alone ends on TURN.
//!
//! The mapping never holds a link up: it is asked after `wg-resp`, in the
//! background, and announced with the roaming messages when (if) it comes.
//! The phone installs no mapper.

use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, PoisonError, RwLock};

use tokio::sync::watch;

/// The protocols a mapping may come from, as named on the wire
/// (`mappedBy`) and in `link_stat` (`portmap`).
pub const PROTOCOLS: [&str; 3] = ["pcp", "nat-pmp", "upnp"];

/// The wire name of `text` among [`PROTOCOLS`], or `None` for a word this
/// build does not know (a newer peer's protocol is counted as unknown, not
/// echoed).
pub fn protocol_word(text: &str) -> Option<&'static str> {
    PROTOCOLS.iter().copied().find(|word| *word == text)
}

/// A live mapping of one local UDP port. Dropping it stops its refresh and
/// deletes it at the router (in the background).
pub struct PortMapping {
    /// Which protocol mapped it: one of [`PROTOCOLS`].
    pub protocol: &'static str,
    /// The mapped public address now; `None` once the mapping is lost (the
    /// router forgot it and refreshing failed). A refresh that gets another
    /// address sends it here.
    pub external: watch::Receiver<Option<SocketAddr>>,
    /// Holds the mapping (its refresh task, its delete on drop).
    pub lease: Box<dyn Send + Sync>,
}

impl std::fmt::Debug for PortMapping {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PortMapping")
            .field("protocol", &self.protocol)
            .field("external", &*self.external.borrow())
            .finish_non_exhaustive()
    }
}

/// What a mapper's [`PortMapper::map`] answers.
pub type MapFuture = Pin<Box<dyn Future<Output = Option<PortMapping>> + Send>>;

/// Maps a local UDP port at this network's router.
pub trait PortMapper: Send + Sync {
    /// Map `local_port` (UDP, every local address); `None` when no router
    /// here maps ports (or the one that does gives no public address).
    fn map(&self, local_port: u16) -> MapFuture;
}

fn slot() -> &'static RwLock<Option<Arc<dyn PortMapper>>> {
    static MAPPER: RwLock<Option<Arc<dyn PortMapper>>> = RwLock::new(None);
    &MAPPER
}

/// Install (or with `None`, remove) this process's mapper: the Mac host at
/// start, unless `CMUX_MOBILE_PORTMAP=0`. Sessions answered later use it.
pub fn install(mapper: Option<Arc<dyn PortMapper>>) {
    *slot().write().unwrap_or_else(PoisonError::into_inner) = mapper;
}

/// The installed mapper, if any.
pub(crate) fn mapper() -> Option<Arc<dyn PortMapper>> {
    slot().read().unwrap_or_else(PoisonError::into_inner).clone()
}

/// What a dialer knows of its peer's mapped endpoints, for `link_stat`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PeerMapped {
    /// The peer's endpoints it labeled `mapped`.
    pub addresses: Vec<SocketAddr>,
    /// Which protocol mapped them (`None`: a protocol this build does not
    /// know, or none named).
    pub protocol: Option<&'static str>,
}

/// How a link uses its peer's port mapping now (`link_stat` `portmap`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PortmapUse {
    /// The protocol that mapped the peer's endpoint (`unknown` when the peer
    /// named none this build knows).
    pub protocol: &'static str,
    /// The link's plain-UDP route goes to that mapped endpoint.
    pub used: bool,
}

impl PeerMapped {
    /// The use of these mappings by a route to `route` (`None`: the peer
    /// offered no mapped endpoint).
    pub fn use_by(&self, route: Option<SocketAddr>) -> Option<PortmapUse> {
        if self.addresses.is_empty() {
            return None;
        }
        Some(PortmapUse {
            protocol: self.protocol.unwrap_or("unknown"),
            used: route.is_some_and(|route| self.addresses.contains(&route)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protocol_words_are_fixed() {
        assert_eq!(protocol_word("pcp"), Some("pcp"));
        assert_eq!(protocol_word("nat-pmp"), Some("nat-pmp"));
        assert_eq!(protocol_word("upnp"), Some("upnp"));
        assert_eq!(protocol_word("<script>"), None);
    }

    #[test]
    fn use_names_the_protocol_and_whether_the_route_is_mapped() {
        let mapped: SocketAddr = "203.0.113.9:41000".parse().unwrap();
        let other: SocketAddr = "203.0.113.9:5000".parse().unwrap();
        assert_eq!(PeerMapped::default().use_by(Some(mapped)), None);
        let peer = PeerMapped { addresses: vec![mapped], protocol: Some("pcp") };
        assert_eq!(peer.use_by(Some(mapped)), Some(PortmapUse { protocol: "pcp", used: true }));
        assert_eq!(peer.use_by(Some(other)), Some(PortmapUse { protocol: "pcp", used: false }));
        assert_eq!(peer.use_by(None), Some(PortmapUse { protocol: "pcp", used: false }));
        let unnamed = PeerMapped { addresses: vec![mapped], protocol: None };
        assert_eq!(unnamed.use_by(Some(mapped)).unwrap().protocol, "unknown");
    }
}

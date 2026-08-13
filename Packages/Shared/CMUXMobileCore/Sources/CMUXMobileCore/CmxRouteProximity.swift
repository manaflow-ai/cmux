import Foundation

/// Network-distance tier for an attach route's endpoint.
///
/// The phone reaches a paired Mac through several transports of varying
/// closeness. When the same Mac advertises more than one reachable endpoint,
/// the closest one should be tried first: a direct same-network address is the
/// lowest latency and needs no relay, a Tailnet address works anywhere the
/// tailnet does, and a relay hop is the last resort. This is the proximity half
/// of issue #6351's "ranks by freshness + proximity (direct LAN > Tailnet >
/// relay)".
///
/// Classification is purely a function of the *endpoint address*, never the
/// route's declared ``CmxAttachTransportKind``: a `tailscale`-kind route may
/// carry a raw CGNAT IP, a MagicDNS hostname, or (in principle) any host, so the
/// address is the reliable signal. ``loopback`` is its own tier rather than the
/// closest LAN tier because a loopback address only reaches the host it runs on
/// — useful on the simulator (where `127.0.0.1` *is* the Mac) but never on a
/// physical phone; callers express that policy via `preferLoopback`.
public enum CmxRouteProximity: Sendable, Equatable, CaseIterable {
    /// `127.0.0.0/8` or `::1` — the same host (simulator / on-device mock host).
    case loopback
    /// An RFC1918 / link-local / unique-local IP literal — direct same-network.
    case lan
    /// Tailscale CGNAT (`100.64.0.0/10`), its IPv6 ULA (`fd7a:115c:a1e0::/48`),
    /// or a MagicDNS `*.ts.net` hostname.
    case tailnet
    /// An iroh peer, a websocket URL, or any other globally-routable / named
    /// host — reachable, but not provably local or on the tailnet.
    case relay
    /// An endpoint that could not be classified (empty/garbage host).
    case unknown
}

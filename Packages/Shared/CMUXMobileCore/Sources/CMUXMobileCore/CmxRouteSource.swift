/// Where a route candidate came from. Used as a freshness/trust tiebreaker when
/// two sources advertise the same endpoint: the cloud registry is authoritative
/// when reachable, a freshly scanned QR is current by construction, and the
/// offline local cache is the least authoritative (it may be stale).
public enum CmxRouteSource: String, Codable, Sendable, CaseIterable {
    /// A freshly scanned pairing QR / attach ticket.
    case qr
    /// A manually entered IP:port.
    case manual
    /// The team-scoped server device registry (`/api/devices`).
    case registry
    /// The phone's persisted offline cache and write-back buffer.
    case localCache
    /// Future LAN mDNS / Bonjour discovery.
    case mdns

    /// Higher wins when two candidates are equally fresh and equally close: the
    /// registry is authoritative when reachable, so its routes rank ahead of the
    /// possibly-stale local cache regardless of the Mac-assigned route priority.
    var authority: Int {
        switch self {
        case .registry: return 4
        case .qr: return 3
        case .manual: return 2
        case .mdns: return 1
        case .localCache: return 0
        }
    }
}

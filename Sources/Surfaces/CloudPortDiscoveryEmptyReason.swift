import Foundation

/// Why a completed Cloud port scan produced no reachable rows.
enum CloudPortDiscoveryEmptyReason: String, Codable, Hashable, Sendable {
    case noListeningService
    case loopbackOnly
}

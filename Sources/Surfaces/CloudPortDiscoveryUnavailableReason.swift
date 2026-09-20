import Foundation

/// Why Cloud port discovery or its in-app route is currently unavailable.
enum CloudPortDiscoveryUnavailableReason: String, Codable, Hashable, Sendable {
    case link
    case transport
    case privateAddress
    case machineAsleep
    case hub
}

import Foundation

/// Why Cloud port discovery or its in-app route is currently unavailable.
public enum CloudPortDiscoveryUnavailableReason: String, Codable, Hashable, Sendable {
    case link
    case transport
    case privateAddress = "private_address"
    case machineAsleep = "machine_asleep"
    case hub
}

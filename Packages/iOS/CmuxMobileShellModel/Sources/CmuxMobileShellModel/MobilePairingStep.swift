import Foundation

/// A user-visible gate in the mobile pairing flow.
public enum MobilePairingStep: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Reachability from this device to the Mac.
    case network
    /// Account verification between this device and the Mac.
    case authentication
    /// Route and pairing-link trust checks before the Mac is accepted.
    case trust
}

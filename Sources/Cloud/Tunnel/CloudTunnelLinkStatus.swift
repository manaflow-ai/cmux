import Foundation
import NetworkExtension

/// `NEVPNStatus` as a plain value, so the coordinator and its tests never
/// touch NetworkExtension types.
enum CloudTunnelLinkStatus: Sendable, Equatable {
    /// No configuration, or the configuration is not loaded yet.
    case invalid
    case disconnected
    case connecting
    case connected
    /// The provider is re-establishing the link after a network change.
    case reasserting
    case disconnecting

    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }
}

public import Foundation

/// The saved VPN configuration's connection state, as NetworkExtension reports it
/// (`NEVPNStatus` without the AppKit-only cases).
public enum CloudTunnelConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(since: Date?)
    case reasserting
    case disconnecting
    case invalid
}

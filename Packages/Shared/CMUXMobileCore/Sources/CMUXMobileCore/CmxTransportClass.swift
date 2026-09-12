import Foundation

/// The class of network path a mobile session is allowed to use.
///
/// This is deliberately independent from the wire protocol. An Iroh session
/// can have LAN or Tailscale reachability hints, while a legacy TCP session
/// can be carried over either class. Keeping the policy vocabulary separate
/// from endpoint plumbing makes adding another path class a single mapping
/// change instead of a new boolean at every call site.
public enum CmxTransportClass: String, Codable, CaseIterable, Hashable, Sendable {
    /// A local-network path.
    case lan
    /// A Tailscale path.
    case tailscale
    /// An Iroh-native path.
    case iroh
    /// A WebSocket path.
    case websocket
    /// A development loopback path.
    case debugLoopback = "debug_loopback"

    /// Localized name for user-facing diagnostics and errors.
    public var displayName: String {
        switch self {
        case .lan: String.cmxModuleLocalized("cmux.transport.class.lan", defaultValue: "LAN")
        case .tailscale: String.cmxModuleLocalized("cmux.transport.class.tailscale", defaultValue: "Tailscale")
        case .iroh: String.cmxModuleLocalized("cmux.transport.class.iroh", defaultValue: "iroh")
        case .websocket: String.cmxModuleLocalized("cmux.transport.class.websocket", defaultValue: "WebSocket")
        case .debugLoopback: String.cmxModuleLocalized("cmux.transport.class.loopback", defaultValue: "Loopback")
        }
    }
}

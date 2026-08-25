import Foundation

/// A concrete path currently carrying application bytes.
///
/// Coordinates are retained only in process memory for the live status line;
/// diagnostics use the corresponding redacted class and never serialize these
/// values.
public enum CmxTransportPath: Codable, Equatable, Hashable, Sendable {
    /// No selected path is currently available.
    case unavailable
    /// A local-network socket path.
    case lan(address: String)
    /// A Tailscale socket path.
    case tailscale(address: String)
    /// An Iroh direct path.
    case irohDirect
    /// An Iroh relay path and optional region.
    case irohRelay(region: String?)
    /// A WebSocket path.
    case websocket
    /// A development loopback path.
    case debugLoopback

    /// The transport class represented by this path.
    public var transportClass: CmxTransportClass? {
        switch self {
        case .unavailable: nil
        case .lan: .lan
        case .tailscale: .tailscale
        case .irohDirect, .irohRelay: .iroh
        case .websocket: .websocket
        case .debugLoopback: .debugLoopback
        }
    }

    /// A compact status-line value. The caller localizes the surrounding UI.
    public var displayValue: String {
        switch self {
        case .unavailable:
            return ""
        /// A local-network status value.
        case let .lan(address):
            return formatted("cmux.transport.path.lanFormat", "LAN · %@", address)
        /// A Tailscale status value.
        case let .tailscale(address):
            return formatted("cmux.transport.path.tailscaleFormat", "Tailscale · %@", address)
        case .irohDirect:
            return localized("cmux.transport.path.irohDirect", "iroh direct")
        /// A relay status value with an optional region.
        case let .irohRelay(region):
            if let region, !region.isEmpty {
                return formatted("cmux.transport.path.irohRelayFormat", "iroh relay %@", region)
            }
            return localized("cmux.transport.path.irohRelay", "iroh relay")
        case .websocket:
            return localized("cmux.transport.path.websocket", "WebSocket")
        case .debugLoopback:
            return localized("cmux.transport.path.loopback", "Loopback")
        }
    }

    private func localized(_ key: StaticString, _ value: String) -> String {
        String(localized: key, defaultValue: String.LocalizationValue(value), bundle: .module)
    }

    private func formatted(
        _ key: StaticString,
        _ value: String,
        _ argument: String
    ) -> String {
        String(
            format: localized(key, value),
            locale: .current,
            argument
        )
    }

    /// Redacted path category suitable for the structured diagnostic ring.
    public var diagnosticPathKind: DiagnosticPathKind {
        switch self {
        case .unavailable: .unknown
        case .lan: .lan
        case .tailscale: .tailscale
        case .irohDirect: .direct
        case .irohRelay: .relay
        case .websocket: .direct
        case .debugLoopback: .loopback
        }
    }
}

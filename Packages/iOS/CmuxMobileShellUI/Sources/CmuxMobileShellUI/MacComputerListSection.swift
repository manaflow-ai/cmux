import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

/// One connection-method section of the Computers list: the method plus the
/// Computers (device + build pairings) configured to use it. Every Computer
/// appears exactly once, under its OWN per-pairing method; the row's endpoint
/// and detail focus follow that method's route.
struct MacComputerListSection: Equatable, Identifiable {
    let method: MobileConnectionMethod
    let computers: [MacComputerSnapshot]

    var id: String { method.rawValue }

    var title: String { method.mobileConnectionMethodName }

    /// Group per-Computer snapshots by their configured connection method,
    /// preserving the input (last-seen-newest-first) order within each
    /// section. Only non-empty sections are returned, Relay first.
    static func sections(from snapshots: [MacComputerSnapshot]) -> [MacComputerListSection] {
        var byMethod: [MobileConnectionMethod: [MacComputerSnapshot]] = [:]
        for snapshot in snapshots {
            byMethod[snapshot.connectionMethod ?? .relay, default: []].append(snapshot)
        }
        return [MobileConnectionMethod.relay, .tailscale].compactMap { method in
            byMethod[method].map { MacComputerListSection(method: method, computers: $0) }
        }
    }
}

extension MobileConnectionMethod {
    /// User-facing name of the connection method ("Relay"/"Tailscale").
    var mobileConnectionMethodName: String {
        switch self {
        case .tailscale:
            L10n.string("mobile.connections.method.tailscale", defaultValue: "Tailscale")
        case .relay:
            L10n.string("mobile.connections.method.relay", defaultValue: "Relay")
        }
    }

    /// The route kind this method dials.
    var routeKind: CmxAttachTransportKind? {
        switch self {
        case .tailscale: .tailscale
        case .relay: .websocket
        }
    }
}

extension CmxAttachTransportKind {
    /// User-facing name of a route's transport, shared by the per-Computer
    /// route diagnostics.
    var mobileConnectionMethodName: String {
        switch self {
        case .iroh:
            L10n.string("mobile.connections.method.iroh", defaultValue: "Iroh")
        case .tailscale:
            L10n.string("mobile.connections.method.tailscale", defaultValue: "Tailscale")
        case .websocket:
            L10n.string("mobile.connections.method.websocket", defaultValue: "WebSocket")
        case .debugLoopback:
            L10n.string("mobile.connections.method.debug", defaultValue: "Debug")
        }
    }
}

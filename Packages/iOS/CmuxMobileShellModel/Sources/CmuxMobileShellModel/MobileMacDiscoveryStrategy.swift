public import Foundation

/// The first-pair route source selected by the DEBUG discovery lab.
public enum MobileMacDiscoveryStrategy: String, CaseIterable, Identifiable, Sendable {
    /// Use every authenticated IRX route the broker and Iroh can provide.
    case automatic
    /// Require an authenticated broker binding with a Tailscale path.
    case tailscale
    /// Require an authenticated managed relay path.
    case relay
    /// Keep the live picker empty so the QR/manual pairing flow is exercised.
    case qr

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .tailscale: "Tailscale"
        case .relay: "Relay"
        case .qr: "QR / Manual"
        }
    }

    public var detail: String {
        switch self {
        case .automatic: "Broker discovery, direct paths, and relay fallback"
        case .tailscale: "Only Macs advertising a private Tailscale path"
        case .relay: "Only Macs with a managed relay path"
        case .qr: "Disable live discovery and use the pairing QR or manual entry"
        }
    }
}

/// Shared DEBUG preference for the first-pair discovery lab.
public enum MobileMacDiscoveryStrategyStore {
    public static let strategyKey = "dev.cmux.mobile.macDiscoveryStrategy.v1"

    public static func current(defaults: UserDefaults = .standard) -> MobileMacDiscoveryStrategy {
        guard let raw = defaults.string(forKey: strategyKey),
              let strategy = MobileMacDiscoveryStrategy(rawValue: raw) else {
            return .automatic
        }
        return strategy
    }
}

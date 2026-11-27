import Foundation

@MainActor
public struct ComputersSettingsActions {
    public var updates: () -> AsyncStream<ComputersSettingsSnapshot>
    public var refresh: () async -> Void
    public var pair: (String) async -> String?
    public var open: (String) async -> Void
    public var unpair: (String) async -> Void
    /// Enables or stops discovery without changing incoming access.
    public var setDiscoveryEnabled: (Bool) async -> Void
    /// Changes this Mac's incoming remote-access preference.
    public var setIncomingAccessEnabled: (Bool) async -> Void
    /// Hides or restores a physical Mac in the sidebar, retaining its pairing.
    public var setHidden: (String, Bool) async -> Void
    public var showPairing: () -> Void

    public init(
        updates: @escaping () -> AsyncStream<ComputersSettingsSnapshot> = { AsyncStream { $0.finish() } },
        refresh: @escaping () async -> Void = {},
        pair: @escaping (String) async -> String? = { _ in nil },
        open: @escaping (String) async -> Void = { _ in },
        unpair: @escaping (String) async -> Void = { _ in },
        setDiscoveryEnabled: @escaping (Bool) async -> Void = { _ in },
        setIncomingAccessEnabled: @escaping (Bool) async -> Void = { _ in },
        setHidden: @escaping (String, Bool) async -> Void = { _, _ in },
        showPairing: @escaping () -> Void = {}
    ) {
        self.updates = updates
        self.refresh = refresh
        self.pair = pair
        self.open = open
        self.unpair = unpair
        self.setDiscoveryEnabled = setDiscoveryEnabled
        self.setIncomingAccessEnabled = setIncomingAccessEnabled
        self.setHidden = setHidden
        self.showPairing = showPairing
    }
}

public extension SettingsHostActions {
    func computersSettingsActions() -> ComputersSettingsActions { ComputersSettingsActions() }
}

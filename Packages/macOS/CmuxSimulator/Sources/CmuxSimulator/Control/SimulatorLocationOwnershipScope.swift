import Foundation

/// Shares per-device location ownership between control-service instances.
public struct SimulatorLocationOwnershipScope: Sendable {
    let registry: SimulatorLocationOwnershipRegistry

    /// Creates an isolated scope, primarily for an independent service graph.
    public init() {
        registry = SimulatorLocationOwnershipRegistry()
    }

    /// The app-wide scope used by default so multiple Simulator panes cannot
    /// replay stale looping routes over newer location mutations.
    public static let shared = SimulatorLocationOwnershipScope()
}

actor SimulatorLocationOwnershipRegistry {
    private var tokenByDeviceIdentifier: [String: UUID] = [:]

    func claim(deviceIdentifier: String) -> UUID {
        let token = UUID()
        tokenByDeviceIdentifier[deviceIdentifier] = token
        return token
    }

    func isCurrent(_ token: UUID, deviceIdentifier: String) -> Bool {
        tokenByDeviceIdentifier[deviceIdentifier] == token
    }
}

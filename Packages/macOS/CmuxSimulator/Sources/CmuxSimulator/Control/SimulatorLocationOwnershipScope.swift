import Foundation

/// Shares per-device location ownership between control-service instances.
public struct SimulatorLocationOwnershipScope: Sendable {
    let registry: SimulatorLocationOwnershipRegistry

    /// Creates an isolated scope, primarily for an independent service graph.
    public init() {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "com.cmux.simulator-location-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        ))
    }

    /// The app-wide scope used by default so multiple Simulator panes cannot
    /// replay stale looping routes over newer location mutations.
    public static let shared = SimulatorLocationOwnershipScope(sharedAcrossProcesses: ())

    private init(sharedAcrossProcesses: Void) {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore())
    }
}

actor SimulatorLocationOwnershipRegistry {
    private var tokenByDeviceIdentifier: [String: UUID] = [:]
    private let store: SimulatorCrossProcessOwnershipStore

    init(store: SimulatorCrossProcessOwnershipStore) {
        self.store = store
    }

    func claim(deviceIdentifier: String) -> UUID {
        let publishedToken = store.claim(namespace: "location", components: [deviceIdentifier])
        tokenByDeviceIdentifier[deviceIdentifier] = publishedToken
        return publishedToken
    }

    func isCurrent(_ token: UUID, deviceIdentifier: String) -> Bool {
        tokenByDeviceIdentifier[deviceIdentifier] == token
            && store.isCurrent(token, namespace: "location", components: [deviceIdentifier])
    }
}

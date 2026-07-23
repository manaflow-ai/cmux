import Foundation

/// Shares per-device location ownership between control-service instances.
public struct SimulatorLocationOwnershipScope: Sendable {
    let registry: SimulatorLocationOwnershipRegistry

    /// Creates an isolated scope for an independent service graph.
    public init(fileManager: FileManager = FileManager(), makeUUID: () -> UUID = UUID.init) {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore(
            directory: fileManager.temporaryDirectory.appendingPathComponent(
                "com.cmux.simulator-location-\(makeUUID().uuidString)",
                isDirectory: true
            )
        ))
    }

    /// Creates a scope backed by a caller-owned directory. App composition
    /// roots pass one stable directory to every pane and worker service.
    public init(directory: URL) {
        registry = SimulatorLocationOwnershipRegistry(store: SimulatorCrossProcessOwnershipStore(
            directory: directory
        ))
    }
}

actor SimulatorLocationOwnershipRegistry {
    private var tokenByDeviceIdentifier: [String: UUID] = [:]
    private let store: SimulatorCrossProcessOwnershipStore

    init(store: SimulatorCrossProcessOwnershipStore) {
        self.store = store
    }

    func claim(deviceIdentifier: String) throws -> UUID {
        let publishedToken = try store.claim(
            namespace: "location",
            components: [deviceIdentifier]
        )
        tokenByDeviceIdentifier[deviceIdentifier] = publishedToken
        return publishedToken
    }

    func isCurrent(_ token: UUID, deviceIdentifier: String) -> Bool {
        tokenByDeviceIdentifier[deviceIdentifier] == token
            && store.isCurrent(token, namespace: "location", components: [deviceIdentifier])
    }
}

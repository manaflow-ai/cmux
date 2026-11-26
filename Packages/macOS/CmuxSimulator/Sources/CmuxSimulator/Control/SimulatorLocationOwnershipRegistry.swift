import Foundation

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

    func makeToken() -> UUID {
        UUID()
    }

    func claim(_ token: UUID, deviceIdentifier: String) throws {
        try store.publish(
            token,
            namespace: "location",
            components: [deviceIdentifier]
        )
        tokenByDeviceIdentifier[deviceIdentifier] = token
    }

    func restore(_ token: UUID, deviceIdentifier: String) throws {
        try claim(token, deviceIdentifier: deviceIdentifier)
    }

    func publishedToken(deviceIdentifier: String) -> UUID? {
        store.currentToken(
            namespace: "location",
            components: [deviceIdentifier]
        )
    }

    func isCurrent(_ token: UUID, deviceIdentifier: String) -> Bool {
        tokenByDeviceIdentifier[deviceIdentifier] == token
            && store.isCurrent(token, namespace: "location", components: [deviceIdentifier])
    }
}

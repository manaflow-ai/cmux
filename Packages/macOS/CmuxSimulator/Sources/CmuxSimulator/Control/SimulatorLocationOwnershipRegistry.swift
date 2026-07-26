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

    func isCurrent(_ token: UUID, deviceIdentifier: String) -> Bool {
        tokenByDeviceIdentifier[deviceIdentifier] == token
            && store.isCurrent(token, namespace: "location", components: [deviceIdentifier])
    }
}

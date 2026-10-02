import Foundation

struct SimulatorLocationRouteRecoveryRecord: Codable, Equatable, Sendable {
    let deviceIdentifier: String
    let committed: SimulatorLocationRouteRecoverySnapshot?
    let pending: SimulatorLocationRoutePendingTransaction?

    private enum CodingKeys: String, CodingKey {
        case version
        case deviceIdentifier
        case committed
        case pending
        case initialCoordinate
        case state
        case ownershipToken
        case ownerProcessIdentity
    }

    init(
        deviceIdentifier: String,
        committed: SimulatorLocationRouteRecoverySnapshot?,
        pending: SimulatorLocationRoutePendingTransaction?
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.committed = committed
        self.pending = pending
    }

    init(
        deviceIdentifier: String,
        initialCoordinate: SimulatorLocationCoordinate,
        state: SimulatorLocationRouteRecoveryState,
        ownershipToken: UUID,
        ownerProcessIdentity: SimulatorProcessIdentity
    ) {
        self.init(
            deviceIdentifier: deviceIdentifier,
            committed: SimulatorLocationRouteRecoverySnapshot(
                initialCoordinate: initialCoordinate,
                state: state,
                ownershipToken: ownershipToken,
                ownerProcessIdentity: ownerProcessIdentity
            ),
            pending: nil
        )
    }

    func preparing(
        replacement: SimulatorLocationRouteRecoverySnapshot?,
        ownershipToken: UUID,
        ownerProcessIdentity: SimulatorProcessIdentity
    ) -> SimulatorLocationRouteRecoveryRecord {
        SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: deviceIdentifier,
            committed: committed,
            pending: SimulatorLocationRoutePendingTransaction(
                ownershipToken: ownershipToken,
                ownerProcessIdentity: ownerProcessIdentity,
                replacement: replacement
            )
        )
    }

    init(
        deviceIdentifier: String,
        replacement: SimulatorLocationRouteRecoverySnapshot,
        ownershipToken: UUID,
        ownerProcessIdentity: SimulatorProcessIdentity
    ) {
        self.init(
            deviceIdentifier: deviceIdentifier,
            committed: nil,
            pending: SimulatorLocationRoutePendingTransaction(
                ownershipToken: ownershipToken,
                ownerProcessIdentity: ownerProcessIdentity,
                replacement: replacement
            )
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIdentifier = try container.decode(String.self, forKey: .deviceIdentifier)
        if container.contains(.committed)
            || container.contains(.pending)
            || container.contains(.version) {
            let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 2
            guard version == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .version,
                    in: container,
                    debugDescription: "Unsupported location recovery journal version."
                )
            }
            committed = try container.decodeIfPresent(
                SimulatorLocationRouteRecoverySnapshot.self,
                forKey: .committed
            )
            pending = try container.decodeIfPresent(
                SimulatorLocationRoutePendingTransaction.self,
                forKey: .pending
            )
            return
        }
        committed = SimulatorLocationRouteRecoverySnapshot(
            initialCoordinate: try container.decode(
                SimulatorLocationCoordinate.self,
                forKey: .initialCoordinate
            ),
            state: try container.decode(
                SimulatorLocationRouteRecoveryState.self,
                forKey: .state
            ),
            ownershipToken: try container.decode(UUID.self, forKey: .ownershipToken),
            ownerProcessIdentity: try container.decode(
                SimulatorProcessIdentity.self,
                forKey: .ownerProcessIdentity
            )
        )
        pending = nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(deviceIdentifier, forKey: .deviceIdentifier)
        try container.encodeIfPresent(committed, forKey: .committed)
        try container.encodeIfPresent(pending, forKey: .pending)
    }
}

import Foundation

struct SimulatorLocationRouteRecoveryRecord: Codable, Equatable, Sendable {
    let deviceIdentifier: String
    let committed: SimulatorLocationRouteRecoverySnapshot?
    let pending: SimulatorLocationRoutePendingTransaction?

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
}

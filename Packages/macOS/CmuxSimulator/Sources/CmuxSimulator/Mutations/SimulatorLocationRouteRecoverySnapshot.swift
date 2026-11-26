import Foundation

struct SimulatorLocationRouteRecoverySnapshot: Codable, Equatable, Sendable {
    let initialCoordinate: SimulatorLocationCoordinate
    let state: SimulatorLocationRouteRecoveryState
    let ownershipToken: UUID
    let ownerProcessIdentity: SimulatorProcessIdentity

    var isOwnedByRunningProcess: Bool {
        ownerProcessIdentity.isRunning
    }

    func adopting(
        ownershipToken: UUID,
        ownerProcessIdentity: SimulatorProcessIdentity,
        state: SimulatorLocationRouteRecoveryState? = nil
    ) -> SimulatorLocationRouteRecoverySnapshot {
        SimulatorLocationRouteRecoverySnapshot(
            initialCoordinate: initialCoordinate,
            state: state ?? self.state,
            ownershipToken: ownershipToken,
            ownerProcessIdentity: ownerProcessIdentity
        )
    }
}

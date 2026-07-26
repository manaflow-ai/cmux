import Foundation

struct SimulatorLocationRouteRecoveryRecord: Codable, Equatable, Sendable {
    let deviceIdentifier: String
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
    ) -> SimulatorLocationRouteRecoveryRecord {
        SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: deviceIdentifier,
            initialCoordinate: initialCoordinate,
            state: state ?? self.state,
            ownershipToken: ownershipToken,
            ownerProcessIdentity: ownerProcessIdentity
        )
    }
}

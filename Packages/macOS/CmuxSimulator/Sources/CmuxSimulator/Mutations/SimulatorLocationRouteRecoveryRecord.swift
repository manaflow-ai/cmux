import Foundation

enum SimulatorLocationRouteRecoveryState: Codable, Equatable, Sendable {
    case running(route: SimulatorLocationRoute, startedAt: Date)
    case paused(route: SimulatorLocationRoute)

    var activeLocationRoute: ActiveLocationRoute {
        switch self {
        case let .running(route, startedAt):
            .running(route: route, startedAt: startedAt)
        case let .paused(route):
            .paused(route: route)
        }
    }
}

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

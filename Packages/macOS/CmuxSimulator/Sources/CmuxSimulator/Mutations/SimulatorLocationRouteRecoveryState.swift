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

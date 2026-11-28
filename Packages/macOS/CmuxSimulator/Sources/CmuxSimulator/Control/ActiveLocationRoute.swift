import Foundation

enum ActiveLocationRoute {
    case running(route: SimulatorLocationRoute, startedAt: Date)
    case paused(route: SimulatorLocationRoute)
}

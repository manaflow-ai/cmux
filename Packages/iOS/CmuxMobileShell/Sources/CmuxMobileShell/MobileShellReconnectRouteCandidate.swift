import CMUXMobileCore

struct MobileShellReconnectRouteCandidate: Equatable, Sendable {
    let route: CmxAttachRoute
    let host: String
    let port: Int
    var routeID: String { route.id }
}

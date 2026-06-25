public import Foundation

/// An immutable set of ``CmxAttachRoute`` values the mobile host advertises for a
/// single listener port.
///
/// Produced by ``MobileRouteResolver`` (the debug-loopback route plus one route
/// per resolved Tailscale host). ``routes`` feeds every host status and ticket
/// payload through ``CmxAttachRoute/mobileHostJSONObject``; ``payload`` is the
/// pre-projected `[[String: Any]]` wire shape for callers that want it directly.
public struct MobileHostRouteSnapshot: Sendable {
    /// The advertised routes, in priority order (debug loopback first when present,
    /// then Tailscale hosts).
    public let routes: [CmxAttachRoute]

    /// Create a snapshot from already-resolved routes.
    public init(routes: [CmxAttachRoute]) {
        self.routes = routes
    }

    /// The routes projected into the `[[String: Any]]` wire shape used by every
    /// mobile-host status and ticket payload.
    public var payload: [[String: Any]] {
        routes.map(\.mobileHostJSONObject)
    }
}

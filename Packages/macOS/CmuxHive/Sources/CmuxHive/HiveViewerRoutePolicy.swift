public import CMUXMobileCore

/// Selects the route kinds shared by pairing, row presentation, and dialing.
public struct HiveViewerRoutePolicy: Equatable, Sendable {
    /// Whether isolated development sessions may dial this machine's loopback.
    public let allowsLoopbackRoutes: Bool

    /// Creates a viewer route policy.
    /// - Parameter allowsLoopbackRoutes: Enable loopback only for development sessions.
    public init(allowsLoopbackRoutes: Bool) {
        self.allowsLoopbackRoutes = allowsLoopbackRoutes
    }

    /// The ordered route kinds supported by the viewer's network runtime.
    public var supportedRouteKinds: [CmxAttachTransportKind] {
        allowsLoopbackRoutes ? [.debugLoopback, .tailscale] : [.tailscale]
    }

    /// Whether a route can be selected under this runtime's policy.
    /// - Parameter route: An advertised or persisted attach route.
    /// - Returns: Whether its transport kind is supported; this is not peer admission.
    public func supports(_ route: CmxAttachRoute) -> Bool {
        route.kind == .tailscale || (allowsLoopbackRoutes && route.kind == .debugLoopback)
    }

    /// Retains only routes that the corresponding viewer runtime can dial.
    /// - Parameter routes: Advertised or persisted routes in preference order.
    /// - Returns: Supported routes without changing their relative order.
    public func supportedRoutes(_ routes: [CmxAttachRoute]) -> [CmxAttachRoute] {
        routes.filter { supports($0) }
    }
}

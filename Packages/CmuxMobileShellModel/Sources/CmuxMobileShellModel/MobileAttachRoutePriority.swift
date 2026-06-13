public import CMUXMobileCore

/// Shared attach-route priority and best-route selection.
///
/// The phone reaches a Mac over the first usable route in priority order. This
/// ordering is the single source of truth used by reconnect, the multi-Mac
/// switcher, the device-tree tap-to-open, and registry-driven auto-attach, so
/// every surface agrees on which route a device will be reached at. It lives in
/// the model package (not privately on the shell) so the pure auto-attach target
/// selector can rank devices by their best reachable route without importing the
/// shell.
public enum MobileAttachRoutePriority {
    /// Whether `left` should be tried before `right`: lower `priority` wins, with
    /// the route `id` as a stable lexicographic tiebreak so the ordering is
    /// deterministic across runs.
    public static func sortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    /// The first `hostPort` route, in priority order, whose transport kind is
    /// supported (an empty `supportedKinds` means "accept any kind"). Returns
    /// `nil` when no priority-ordered route is both a `hostPort` endpoint and a
    /// supported kind, i.e. the device is not reachable on this client.
    ///
    /// - Parameter rejectLoopback: When `true`, loopback routes (`127.0.0.1` /
    ///   `::1`) are skipped. On a physical phone a loopback route names the phone
    ///   itself, never the Mac, and loopback is in the Stack-auth-trusted set, so
    ///   auto-selecting it would dial localhost and could hand the Stack bearer to
    ///   whatever local process answers. The simulator (where `127.0.0.1` IS the
    ///   host Mac) passes `false`.
    public static func firstReachableHostPort(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        rejectLoopback: Bool = false
    ) -> (host: String, port: Int)? {
        let supported = Set(supportedKinds)
        for route in routes.sorted(by: sortsBefore) {
            if !supported.isEmpty, !supported.contains(route.kind) {
                continue
            }
            if rejectLoopback, MobileShellRouteAuthPolicy.routeIsLoopback(route) {
                continue
            }
            if case let .hostPort(host, port) = route.endpoint {
                return (host, port)
            }
        }
        return nil
    }
}

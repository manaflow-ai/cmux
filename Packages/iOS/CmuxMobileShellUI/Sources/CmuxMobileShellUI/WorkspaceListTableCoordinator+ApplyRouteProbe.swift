#if os(iOS) && DEBUG
import Foundation

/// DEBUG-only observation of which route a coordinator's most recent
/// configuration update took, isolated from the production type per the
/// source policy on test-only seams (mirrors how
/// `WorkspaceListScrollMetricsProbe` isolates DEBUG instrumentation). The
/// coordinator's `#if DEBUG` call sites record here; package tests read the
/// route back through ``WorkspaceListTableCoordinator/lastPayloadApplyRoute``.
extension WorkspaceListTableCoordinator {
    /// How one configuration update reached the table.
    enum PayloadApplyRoute: Equatable {
        /// No row renders differently; the table was not touched.
        case noChange
        /// Payload-only changes with stable heights; the visible changed
        /// cells were re-configured in place, listed here by item id.
        case reconfiguredInPlace([String])
        /// Structure or a row height changed; a snapshot was applied.
        case tableReload
    }

    /// The most recent update's route, or nil before the first update.
    var lastPayloadApplyRoute: PayloadApplyRoute? {
        WorkspaceListApplyRouteProbe.lastRoute(for: self)
    }

    func recordPayloadApplyRoute(_ route: PayloadApplyRoute) {
        WorkspaceListApplyRouteProbe.record(route, for: self)
    }
}

/// Registry with weak coordinator keys: an entry dies with its coordinator,
/// so nothing accumulates over a DEBUG session and a new coordinator reusing
/// a freed address can never read a predecessor's route.
@MainActor
private enum WorkspaceListApplyRouteProbe {
    private final class RouteBox {
        let route: WorkspaceListTableCoordinator.PayloadApplyRoute
        init(_ route: WorkspaceListTableCoordinator.PayloadApplyRoute) {
            self.route = route
        }
    }

    private static let lastRoutesByCoordinator =
        NSMapTable<WorkspaceListTableCoordinator, RouteBox>.weakToStrongObjects()

    static func record(
        _ route: WorkspaceListTableCoordinator.PayloadApplyRoute,
        for coordinator: WorkspaceListTableCoordinator
    ) {
        lastRoutesByCoordinator.setObject(RouteBox(route), forKey: coordinator)
    }

    static func lastRoute(
        for coordinator: WorkspaceListTableCoordinator
    ) -> WorkspaceListTableCoordinator.PayloadApplyRoute? {
        lastRoutesByCoordinator.object(forKey: coordinator)?.route
    }
}
#endif

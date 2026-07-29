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
        case snapshotApply
    }

    /// The most recent update's route, or nil before the first update.
    var lastPayloadApplyRoute: PayloadApplyRoute? {
        WorkspaceListApplyRouteProbe.lastRoute(for: self)
    }

    func recordPayloadApplyRoute(_ route: PayloadApplyRoute) {
        WorkspaceListApplyRouteProbe.record(route, for: self)
    }
}

/// Registry keyed by coordinator identity. Entries for deallocated
/// coordinators linger, which is acceptable for a DEBUG facility whose
/// population is bounded by the coordinators a test run creates.
@MainActor
private enum WorkspaceListApplyRouteProbe {
    private static var lastRoutesByCoordinator:
        [ObjectIdentifier: WorkspaceListTableCoordinator.PayloadApplyRoute] = [:]

    static func record(
        _ route: WorkspaceListTableCoordinator.PayloadApplyRoute,
        for coordinator: WorkspaceListTableCoordinator
    ) {
        lastRoutesByCoordinator[ObjectIdentifier(coordinator)] = route
    }

    static func lastRoute(
        for coordinator: WorkspaceListTableCoordinator
    ) -> WorkspaceListTableCoordinator.PayloadApplyRoute? {
        lastRoutesByCoordinator[ObjectIdentifier(coordinator)]
    }
}
#endif

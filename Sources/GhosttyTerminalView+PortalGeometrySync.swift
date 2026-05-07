import AppKit

extension GhosttyTerminalView {
    static func shouldSynchronizePortalGeometryImmediately(
        hostInLiveResize: Bool,
        windowInLiveResize: Bool,
        interactiveGeometryResizeActive: Bool
    ) -> Bool {
        hostInLiveResize || windowInLiveResize || interactiveGeometryResizeActive
    }

    static func synchronizePortalGeometry(
        for host: HostContainerView,
        coordinator: Coordinator
    ) {
        let geometryRevision = host.geometryRevision
        guard coordinator.lastSynchronizedHostGeometryRevision != geometryRevision else { return }
        coordinator.lastSynchronizedHostGeometryRevision = geometryRevision
        let window = host.window
        if shouldSynchronizePortalGeometryImmediately(
            hostInLiveResize: host.inLiveResize,
            windowInLiveResize: window?.inLiveResize == true,
            interactiveGeometryResizeActive: TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive
        ) {
            TerminalWindowPortalRegistry.synchronizeForAnchor(host)
            return
        }
        // Avoid synchronizing the terminal portal while AppKit is still inside
        // the current layout turn. Re-entrant syncs here can wedge window resize
        // handling and leave the app spinning on the wait cursor.
        guard let window else { return }
        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
    }
}

import AppKit

enum TerminalPortalGeometryFramePolicy {
    static func portalFrameInWindow(
        anchorFrame: NSRect,
        paneContainerFrame: NSRect?
    ) -> NSRect {
        guard let paneContainerFrame,
              shouldUsePaneContainerHorizontalFrame(
                anchorFrame: anchorFrame,
                paneContainerFrame: paneContainerFrame
              ) else {
            return anchorFrame
        }

        return NSRect(
            x: paneContainerFrame.origin.x,
            y: anchorFrame.origin.y,
            width: paneContainerFrame.size.width,
            height: anchorFrame.size.height
        )
    }

    private static func shouldUsePaneContainerHorizontalFrame(
        anchorFrame: NSRect,
        paneContainerFrame: NSRect
    ) -> Bool {
        guard hasFiniteGeometry(anchorFrame),
              hasFiniteGeometry(paneContainerFrame),
              anchorFrame.width > 1,
              anchorFrame.height > 1,
              paneContainerFrame.width > 1,
              paneContainerFrame.height > 1 else {
            return false
        }

        let verticalOverlap = min(anchorFrame.maxY, paneContainerFrame.maxY)
            - max(anchorFrame.minY, paneContainerFrame.minY)
        guard verticalOverlap > min(anchorFrame.height, paneContainerFrame.height) * 0.5 else {
            return false
        }

        // Bonsplit owns horizontal pane geometry in both expand and shrink
        // directions. The terminal anchor remains the source for the vertical
        // band, but using anchor width here can make Ghostty chase SwiftUI's
        // intermediate sidebar animation frames.
        return true
    }

    private static func hasFiniteGeometry(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite &&
            rect.origin.y.isFinite &&
            rect.size.width.isFinite &&
            rect.size.height.isFinite
    }
}

extension NSView {
    func terminalPortalNearestBonsplitPaneContainer() -> NSView? {
        var current: NSView? = self
        var fallback: NSView?
        while let view = current {
            let className = NSStringFromClass(type(of: view))
            if className.contains("PaneContainerView") { return view }
            if fallback == nil, className.contains("PaneDragContainerView") {
                fallback = view
            }
            current = view.superview
        }
        return fallback
    }
}

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

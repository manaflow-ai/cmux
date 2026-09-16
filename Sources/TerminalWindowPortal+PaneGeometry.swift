import AppKit
import CmuxTerminalCore

// MARK: - Pane geometry publication

extension WindowTerminalPortal {
    /// Inner viewport changes (scrollbars or a content-width setting) use the
    /// same portal publication path even when the pane's outer frame is fixed.
    func requestPaneGeometryCommit(for hostedView: GhosttySurfaceScrollView) {
        let hostedId = ObjectIdentifier(hostedView)
        guard let entry = entriesByHostedId[hostedId], entry.visibleInUI,
              !entry.needsSettledCommit, !hostedView.isHidden,
              hostedView.window === window else { return }
        let size = hostedView.surfaceView.frame.size
        let committed = hostedView.surfaceView.terminalSurface?.committedPaneGeometry
        guard committed?.size != size || committed?.backingScale != window?.backingScaleFactor else { return }
        markNeedsSettledCommit(for: hostedId)
        scheduleExternalGeometrySynchronize(forceImmediate: false)
    }

    /// Marks a visible entry for the next settled geometry commit.
    ///
    /// A new settlement episode gets the full convergence budget. Repeated
    /// frame notifications in the same episode keep the budget already in
    /// progress so a noisy layout cannot refill retries indefinitely.
    func markNeedsSettledCommit(for hostedId: ObjectIdentifier) {
        guard var entry = entriesByHostedId[hostedId] else { return }
        let wasPending = entry.needsSettledCommit
        entry.needsSettledCommit = true
        entriesByHostedId[hostedId] = entry
        if !wasPending {
            geometrySettlementPassesRemaining = 4
        }
    }

    /// Publishes the resting size of every visible entry whose frame changed
    /// since its last commit. This and the drag-tick commit in
    /// `synchronizeHostedView` are the only two paths that give a terminal a
    /// size, so a hidden, detached, or still-moving frame cannot reach it.
    func commitSettledPaneGeometries() {
        guard !isInteractiveGeometryActive else { return }
        for hostedId in entriesByHostedId.keys {
            guard let entry = entriesByHostedId[hostedId], entry.visibleInUI,
                  entry.needsSettledCommit, let hostedView = entry.hostedView,
                  !hostedView.isHidden, hostedView.window === window else { continue }
            guard hostedView.commitPortalGeometry(phase: .settled) else { continue }
            entriesByHostedId[hostedId]?.needsSettledCommit = false
        }
    }

    /// Whether frames written right now are drag ticks the user is watching.
    var isInteractiveGeometryActive: Bool {
        isWindowLiveResizeActive || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window)
    }
}

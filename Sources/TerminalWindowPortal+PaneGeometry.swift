import AppKit
import CmuxTerminalCore

// MARK: - Pane geometry publication

extension WindowTerminalPortal {
    /// Publishes the resting size of every visible entry whose frame changed
    /// since its last commit. This and the drag-tick commit in
    /// `synchronizeHostedView` are the only two paths that give a terminal a
    /// size, so a hidden, detached, or still-moving frame cannot reach it.
    func commitSettledPaneGeometries() {
        for hostedId in entriesByHostedId.keys {
            guard let entry = entriesByHostedId[hostedId], entry.visibleInUI,
                  entry.needsSettledCommit, let hostedView = entry.hostedView,
                  !hostedView.isHidden, hostedView.window === window else { continue }
            // Only an accepted commit retires the request; a frame the view
            // could not publish (no window, empty) stays pending.
            if hostedView.commitPortalGeometry(phase: .settled) {
                entriesByHostedId[hostedId]?.needsSettledCommit = false
            }
        }
    }

    /// Whether frames written right now are drag ticks the user is watching.
    var isInteractiveGeometryActive: Bool {
        isWindowLiveResizeActive || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window)
    }

    /// Records that the bounded settlement retry ran out while layout was
    /// still changing. Nothing is published; the pending commits wait for the
    /// next pass that observes stable geometry.
    func noteSettlementExhausted() {
#if DEBUG
        let pending = entriesByHostedId.values.filter { $0.visibleInUI && $0.needsSettledCommit }.count
        cmuxDebugLog("portal.settle.exhausted pending=\(pending)")
#endif
    }
}

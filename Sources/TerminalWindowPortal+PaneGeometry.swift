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
            entriesByHostedId[hostedId]?.needsSettledCommit = false
            _ = hostedView.commitPortalGeometry(phase: .settled)
        }
    }

    /// Whether frames written right now are drag ticks the user is watching.
    var isInteractiveGeometryActive: Bool {
        isWindowLiveResizeActive || TerminalWindowPortalRegistry.isInteractiveGeometryResizeActive(in: window)
    }
}

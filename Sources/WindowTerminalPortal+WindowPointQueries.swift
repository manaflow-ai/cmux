import AppKit
import ObjectiveC
#if DEBUG
import Bonsplit
#endif


// MARK: - Window point hit-test queries
extension WindowTerminalPortal {
    private func hostedScrollViewAtWindowPoint(_ windowPoint: NSPoint) -> (view: GhosttySurfaceScrollView, point: NSPoint)? {
        guard ensureInstalled() else { return nil }
        let point = hostView.convert(windowPoint, from: nil)

        for subview in hostView.subviews.reversed() {
            guard let hostedView = subview as? GhosttySurfaceScrollView,
                  entriesByHostedId[ObjectIdentifier(hostedView)] != nil,
                  !hostedView.isHidden,
                  hostedView.frame.contains(point) else { continue }
            return (hostedView, hostedView.convert(point, from: hostView))
        }

        return nil
    }

    func viewAtWindowPoint(_ windowPoint: NSPoint) -> NSView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.hitTest(hit.point) ?? hit.view
    }

    func terminalViewAtWindowPoint(_ windowPoint: NSPoint) -> GhosttyNSView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.terminalViewForDrop(at: hit.point)
    }

    func terminalPaneDropTargetAtWindowPoint(_ windowPoint: NSPoint) -> TerminalPaneDropTargetView? {
        guard let hit = hostedScrollViewAtWindowPoint(windowPoint) else { return nil }
        return hit.view.paneDropTargetForDrop(at: hit.point)
    }
}

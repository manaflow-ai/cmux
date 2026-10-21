import AppKit
public import CmuxNextDesign

/// The pane's layout spring landed: the grid held while it moved goes to the owner now, once.
extension TerminalSurfaceView: PaneMotionSettling {
    public func paneMotionDidSettle() {
        guard isHeldGridPending else { return }
        updateSurfaceSize()
    }
}

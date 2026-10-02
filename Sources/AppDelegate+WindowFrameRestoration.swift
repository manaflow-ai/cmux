import AppKit

extension AppDelegate {
    /// Reasserts the main-window visible-frame invariant after AppKit restores
    /// window geometry outside cmux's launch and display-topology restore paths.
    func fitRestoredMainWindowFramesIfNeeded(
        windows: [NSWindow]? = nil,
        displays: [SessionDisplayGeometry]? = nil
    ) {
        guard !isTerminatingApp else { return }
        let candidateWindows = windows ?? mainWindowsForVisibilityController()
        let availableDisplays = displays ?? currentDisplayGeometries().available
        MainWindowVisibleFrameFitRescue().performFitIfNeeded(
            displays: availableDisplays,
            windows: candidateWindows
        )
    }

    func applicationDidUnhide(_ notification: Notification) {
        fitRestoredMainWindowFramesIfNeeded()
    }
}

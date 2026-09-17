import AppKit
import CmuxWindowing

extension AppDelegate {
    /// Reasserts the main-window visible-frame invariant after AppKit restores
    /// window geometry outside cmux's launch and display-topology restore paths.
    @discardableResult
    func fitRestoredMainWindowFramesIfNeeded(
        windows: [NSWindow]? = nil,
        displays: [SessionDisplayGeometry]? = nil
    ) -> Bool {
        guard !isTerminatingApp else { return false }
        let candidateWindows = windows ?? mainWindowsForVisibilityController()
        let availableDisplays = displays ?? currentDisplayGeometries().available
        return MainWindowVisibleFrameFitRescue().performFitIfNeeded(
            displays: availableDisplays,
            windows: candidateWindows
        )
    }

    func applicationDidUnhide(_ notification: Notification) {
        fitRestoredMainWindowFramesIfNeeded()
    }

    /// Schedules the single topology reconcile path when AppKit reports a late
    /// main-window geometry change during display reconfiguration.
    func handleMainWindowGeometryChange(_ window: NSWindow) {
        guard !isTerminatingApp,
              isMainTerminalWindow(window) else {
            return
        }

        let displays = currentDisplayGeometries().available
        let fullscreenNeedsFit = window.styleMask.contains(.fullScreen)
            && MainWindowVisibleFrameFitCore().fittedFullscreenFrame(
                for: window.frame,
                displays: displays
            ) != nil
        let topologyChanged = MainWindowVisibleFrameFitCore()
            .trustedTopologySignature(of: displays)
            .map { didObserveUnknownVisibleFrameFitTopology || $0 != lastVisibleFrameFitTopologySignature }
            ?? false
        guard topologyChanged || fullscreenNeedsFit else { return }

        if fullscreenNeedsFit {
            didObserveUnknownVisibleFrameFitTopology = true
            visibleFrameFitTopologyRetryBudget = max(
                visibleFrameFitTopologyRetryBudget,
                Self.screenChangeReconcileRetryLimit
            )
        }
        scheduleScreenChangeReconcileWhenIdle()
    }
}

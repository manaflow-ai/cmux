import AppKit

extension MainWindowVisibilityController {
    func discardClosedWindow(_ window: NSWindow) {
        appHiddenWindowRestoreTargets.removeAll { $0 === window }
        dismissedWindowRestoreTargets.removeAll { $0 === window }
        if pendingApplicationActivationKeyRestoreTarget === window {
            pendingApplicationActivationKeyRestoreTarget = nil
        }
        log("discardClosed", reason: .titlebarDismiss, windows: [window])
    }
}

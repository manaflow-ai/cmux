import AppKit

extension MainWindowVisibilityController {
    /// Whether an ordered-out window is still owned by a pending visibility
    /// transition and must remain addressable for restore and explicit focus.
    func windowRemainsInRestoreTopology(_ window: NSWindow) -> Bool {
        appHiddenWindowRestoreTargets.contains { $0 === window }
            || dismissedWindowRestoreTargets.contains { $0 === window }
            || pendingApplicationActivationKeyRestoreTarget === window
    }

    func discardClosedWindow(_ window: NSWindow) {
        appHiddenWindowRestoreTargets.removeAll { $0 === window }
        dismissedWindowRestoreTargets.removeAll { $0 === window }
        if pendingApplicationActivationKeyRestoreTarget === window {
            pendingApplicationActivationKeyRestoreTarget = nil
        }
        log("discardClosed", reason: .titlebarDismiss, windows: [window])
    }
}

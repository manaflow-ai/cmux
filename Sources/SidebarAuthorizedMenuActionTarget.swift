import AppKit

/// Retains the original native command while the guarded menu is tracking.
@MainActor
final class SidebarAuthorizedMenuActionTarget: NSObject {
    private let authorization: SidebarActionAuthorization
    private let originalAction: Selector
    private let originalTarget: AnyObject?

    init(authorization: SidebarActionAuthorization, action: Selector, target: AnyObject?) {
        self.authorization = authorization
        self.originalAction = action
        self.originalTarget = target
    }

    @objc func invokeMenuCommand(_ sender: NSMenuItem) {
        authorization.perform {
            _ = NSApplication.shared.sendAction(originalAction, to: originalTarget, from: sender)
        }
    }
}

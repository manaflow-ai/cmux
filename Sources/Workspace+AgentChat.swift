import AppKit

extension Workspace {
    func performSurfaceTabBarNewAgentChatAction(presentingWindow: NSWindow?) {
        guard let owningTabManager else { return }
        _ = AppDelegate.shared?.executeConfiguredCmuxAction(
            id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
            tabManager: owningTabManager,
            preferredWindow: presentingWindow
        )
    }
}

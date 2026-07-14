import AppKit

extension TabManager {
    @discardableResult
    func openSidebarPullRequestURL(
        _ url: URL,
        inWorkspace workspaceId: UUID?,
        preferSplitRight: Bool
    ) -> Bool {
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser() {
            let openedPanel: BrowserPanel?
            if let workspaceId {
                openedPanel = openBrowser(
                    inWorkspace: workspaceId,
                    url: url,
                    preferSplitRight: preferSplitRight,
                    insertAtEnd: true
                )
            } else {
                openedPanel = openBrowser(url: url, insertAtEnd: true)
            }
            if openedPanel != nil { return true }
        }
        return NSWorkspace.shared.open(url)
    }
}

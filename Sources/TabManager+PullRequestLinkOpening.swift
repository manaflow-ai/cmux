import AppKit

extension TabManager {
    @discardableResult
    func openSidebarPullRequestURL(
        _ url: URL,
        inWorkspace workspaceId: UUID?,
        preferSplitRight: Bool
    ) -> Bool {
        if BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser() {
            let openedSurfaceID: UUID?
            if let workspaceId {
                openedSurfaceID = openBrowser(
                    inWorkspace: workspaceId,
                    url: url,
                    preferSplitRight: preferSplitRight,
                    insertAtEnd: true
                )
            } else {
                openedSurfaceID = openBrowser(url: url, insertAtEnd: true)
            }
            if openedSurfaceID != nil { return true }
        }
        return NSWorkspace.shared.open(url)
    }
}

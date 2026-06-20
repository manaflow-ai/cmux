import Foundation

extension BrowserPanel {
    func configureMoveTabToNewWorkspaceContextMenu(for webView: CmuxWebView) {
        webView.contextMenuCanMoveTabToNewWorkspace = { [weak self] in
            guard let self else { return false }
            return AppDelegate.shared?.canMoveSurfaceToNewWorkspace(panelId: self.id) ?? false
        }
        webView.contextMenuMoveTabToNewWorkspace = { [weak self] in
            guard let self else { return false }
            return AppDelegate.shared?.moveSurfaceToNewWorkspace(
                panelId: self.id,
                focus: true,
                focusWindow: false
            ) != nil
        }
    }
}

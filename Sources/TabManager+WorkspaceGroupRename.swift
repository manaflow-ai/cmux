import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Synchronizes a generated group anchor through the same user-title path
    /// as a direct workspace rename.
    func workspaceGroupGeneratedAnchorNameDidChange(_ anchor: Workspace, name: String) {
        guard anchor.owningTabManager === self,
              workspacesById[anchor.id] === anchor,
              anchor.groupId != nil else { return }
        _ = setCustomTitle(
            tabId: anchor.id,
            title: name,
            source: .user,
            propagateToRemoteTmux: false
        )
    }
}

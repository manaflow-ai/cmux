import AppKit
import SwiftUI

extension TabItemView {
    func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }
}

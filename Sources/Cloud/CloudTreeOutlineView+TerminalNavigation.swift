import Foundation

extension CloudTreeOutlineView.Coordinator {
    /// Resolves a terminal row's workspace parent before dispatching its open verb.
    func openTerminalRow(_ node: CloudTreeNode, row: CloudTreeTerminalRow) {
        if let parent = outlineView?.parent(forItem: node) as? CloudTreeNode,
           case .workspace(let machine, let workspace, _, _, let openIn) = parent.kind {
            guard machine == row.resource.machine,
                  let group = parent.dragGroup,
                  group.remoteWorkspaceID == workspace.id,
                  row.remoteView?.workspace.id == nil || row.remoteView?.workspace.id == workspace.id else {
                #if DEBUG
                cmuxDebugLog("cloudTree.open terminal staleOwner resource=\(row.resource.id.rawValue)")
                #endif
                return
            }
            nodeActions.openRemoteTerminal(machine, group, row.resource.id, row.remoteView, openIn)
        } else if let view = row.remoteView {
            #if DEBUG
            cmuxDebugLog("cloudTree.open terminal missingOwner resource=\(row.resource.id.rawValue) view=\(view.tabID)")
            #endif
        } else {
            // Pool terminals have no owner; retain their selected-workspace behavior.
            nodeActions.project(row.resource.id, .tab, true)
        }
    }
}

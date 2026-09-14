import Foundation

extension WorkspaceGroupCoordinator {
    /// Removes a cmux-created anchor from an anchor-only group after explicit
    /// caller intent has been validated by ``ungroupWorkspaceGroup``.
    func removeGeneratedAnchorWorkspace(
        group: WorkspaceGroup,
        groupId: UUID,
        memberIds: [UUID]
    ) -> WorkspaceGroupUngroupResult {
        guard group.anchorWorkspaceProvenance == .generated,
              let liveAnchorID = group.liveAnchorWorkspaceId else {
            return .generatedAnchorNotOwned
        }
        let childCount = memberIds.reduce(into: 0) { count, id in
            if id != liveAnchorID { count += 1 }
        }
        guard childCount == 0 else {
            return .generatedAnchorRequiresAnchorOnly(memberWorkspaceCount: childCount)
        }
        guard let host,
              let anchor = model.tabs.first(where: { $0.id == liveAnchorID }) else {
            return .generatedAnchorRemovalFailed
        }
        // A window must retain one workspace. Match the existing explicit
        // group-delete path by creating an ungrouped replacement before
        // removing the generated anchor when it is the last tab.
        if model.tabs.count <= 1 {
            _ = host.createWorkspaceForGroup(
                title: nil,
                workingDirectory: nil,
                initialSurface: .terminal,
                initialBrowserURL: nil,
                initialBrowserOmnibarVisible: false,
                initialBrowserTransparentBackground: false,
                inheritWorkingDirectory: true,
                select: false,
                applyCreationTitleAsCustomTitle: true
            )
            guard model.tabs.count > 1 else {
                return .generatedAnchorRemovalFailed
            }
        }
        let countBefore = model.tabs.count
        host.closeWorkspaceForGroupDeletion(anchor, recordHistory: false)
        guard model.tabs.count < countBefore,
              !model.tabs.contains(where: { $0.id == anchor.id }) else {
            return .generatedAnchorRemovalFailed
        }
        // Closing a pinned anchor intentionally leaves an empty durable group.
        // This explicit cleanup request owns the whole anchor-only group, so
        // remove that now-empty record after the workspace close succeeds.
        model.workspaceGroups.removeAll { $0.id == groupId }
        guard !model.workspaceGroups.contains(where: { $0.id == groupId }) else {
            return .generatedAnchorRemovalFailed
        }
        host.workspaceOrderDidChange(movedWorkspaceIds: [anchor.id])
        return .removedGeneratedAnchor(workspaceID: anchor.id)
    }
}

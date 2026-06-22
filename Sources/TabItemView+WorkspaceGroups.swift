import CmuxSidebar
import SwiftUI

extension TabItemView {
    /// Precomputed inputs for the lifted ``SidebarWorkspaceGroupContextMenuSection``.
    ///
    /// Resolves which of `targetIds` are eligible for grouping (group anchors are
    /// excluded), whether they all share one group, whether any is grouped, and
    /// the offered group snapshots. The lifted section renders from these values
    /// only, so it never reads the live tab-manager.
    struct WorkspaceGroupMenuInputs {
        let groups: [SidebarWorkspaceGroupMenuItem]
        let eligibleTargetIds: [UUID]
        let allTargetsInSameGroupId: UUID?
        let hasAnyGroupedTarget: Bool
    }

    func workspaceGroupMenuInputs(targetIds: [UUID]) -> WorkspaceGroupMenuInputs {
        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)

        let allTargetsInSameGroup: UUID? = {
            let groupIds = eligibleTargets.map(\.groupId)
            guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }()
        let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

        let groups = workspaceGroupMenuSnapshot.items.map { item in
            SidebarWorkspaceGroupMenuItem(id: item.id, name: item.name)
        }

        return WorkspaceGroupMenuInputs(
            groups: groups,
            eligibleTargetIds: eligibleTargetIds,
            allTargetsInSameGroupId: allTargetsInSameGroup,
            hasAnyGroupedTarget: hasAnyGroupedTarget
        )
    }

    func promptNewWorkspaceGroup(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds)
    }
}

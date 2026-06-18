import SwiftUI

extension TabItemView {
    @ViewBuilder
    func workspaceGroupContextMenuSection(
        targetIds: [UUID],
        isMulti: Bool
    ) -> some View {
        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)
        if !eligibleTargetIds.isEmpty {
            let groups = workspaceGroupMenuSnapshot.items
            let allTargetsInSameGroup: UUID? = {
                let groupIds = eligibleTargets.map(\.groupId)
                guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else {
                    return nil
                }
                return first
            }()
            let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

            let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
            let groupSelectedLabel = isMulti
                ? String(
                    localized: "contextMenu.workspaceGroup.newFromSelection",
                    defaultValue: "New Group from Selection"
                )
                : String(
                    localized: "contextMenu.workspaceGroup.newFromWorkspace",
                    defaultValue: "New Group from Workspace"
                )
            if let key = groupSelectedShortcut.keyEquivalent {
                Button(groupSelectedLabel) {
                    promptNewWorkspaceGroup(workspaceIds: eligibleTargetIds)
                }
                .keyboardShortcut(key, modifiers: groupSelectedShortcut.eventModifiers)
            } else {
                Button(groupSelectedLabel) {
                    promptNewWorkspaceGroup(workspaceIds: eligibleTargetIds)
                }
            }

            Menu(
                String(
                    localized: "contextMenu.workspaceGroup.moveTo",
                    defaultValue: "Move to Group"
                )
            ) {
                ForEach(groups) { group in
                    Button(group.name) {
                        for id in eligibleTargetIds {
                            tabManager.addWorkspaceToGroup(workspaceId: id, groupId: group.id)
                        }
                    }
                    .disabled(allTargetsInSameGroup == group.id)
                }
            }
            .disabled(groups.isEmpty)

            if hasAnyGroupedTarget {
                Button(
                    String(
                        localized: "contextMenu.workspaceGroup.remove",
                        defaultValue: "Remove from Group"
                    )
                ) {
                    for id in eligibleTargetIds {
                        tabManager.removeWorkspaceFromGroup(workspaceId: id)
                    }
                }
            }
        }
    }

    func promptNewWorkspaceGroup(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds)
    }
}

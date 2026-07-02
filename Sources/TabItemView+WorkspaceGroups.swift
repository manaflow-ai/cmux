import SwiftUI

extension TabItemView {
    @ViewBuilder
    func workspaceGroupContextMenuSection(
        targetIds: [UUID],
        isMulti: Bool
    ) -> some View {
        let newWorkspaceGroupShortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
        let newWorkspaceGroupLabel = String(
            localized: "contextMenu.workspaceGroup.newEmpty",
            defaultValue: "New Empty Workspace Group"
        )
        let canCreateEmptyWorkspaceGroup = tabManager.selectedTab?.isRemoteTmuxMirror != true
        if let key = newWorkspaceGroupShortcut.keyEquivalent {
            Button(newWorkspaceGroupLabel) {
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
            }
            .keyboardShortcut(key, modifiers: newWorkspaceGroupShortcut.eventModifiers)
            .disabled(!canCreateEmptyWorkspaceGroup)
        } else {
            Button(newWorkspaceGroupLabel) {
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
            }
            .disabled(!canCreateEmptyWorkspaceGroup)
        }

        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)
        if !eligibleTargetIds.isEmpty {
            let groups = workspaceGroupMenuSnapshot.items
            let moveToGroupMenuState = WorkspaceGroupMoveToMenuState(groups: groups)
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

            let moveToGroupLabel = String(
                localized: "contextMenu.workspaceGroup.moveTo",
                defaultValue: "Move to Group"
            )
            if moveToGroupMenuState.rendersSubmenu {
                Menu(moveToGroupLabel) {
                    ForEach(groups) { group in
                        Button(group.name) {
                            for id in eligibleTargetIds {
                                tabManager.addWorkspaceToGroup(workspaceId: id, groupId: group.id)
                            }
                        }
                        .disabled(allTargetsInSameGroup == group.id)
                    }
                }
            } else {
                Button(moveToGroupLabel) {}
                    .disabled(true)
            }

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

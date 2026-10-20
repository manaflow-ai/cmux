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
        let context = snapshot.contextMenu
        let canCreateEmptyWorkspaceGroup = context.canCreateEmptyGroup
        if let key = newWorkspaceGroupShortcut.keyEquivalent {
            Button(newWorkspaceGroupLabel) {
                actions.createEmptyGroup()
            }
            .keyboardShortcut(key, modifiers: newWorkspaceGroupShortcut.eventModifiers)
            .disabled(!canCreateEmptyWorkspaceGroup)
        } else {
            Button(newWorkspaceGroupLabel) {
                actions.createEmptyGroup()
            }
            .disabled(!canCreateEmptyWorkspaceGroup)
        }

        let eligibleTargetIds = context.eligibleGroupTargetIds
        if !eligibleTargetIds.isEmpty {
            let groups = context.groupMenuSnapshot.items
            let moveToGroupMenuState = WorkspaceGroupMoveToMenuState(groups: groups)
            let allTargetsInSameGroup = context.allEligibleTargetsGroupId
            let hasAnyGroupedTarget = context.hasGroupedEligibleTarget

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
                            actions.addTargetsToGroup(eligibleTargetIds, group.id)
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
                    actions.removeTargetsFromGroup(eligibleTargetIds)
                }
            }
        }
    }

    func promptNewWorkspaceGroup(workspaceIds: [UUID]) {
        guard !workspaceIds.isEmpty else { return }
        actions.createGroup(workspaceIds)
    }
}

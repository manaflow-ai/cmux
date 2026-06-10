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

            if isMulti {
                // Multi-select grouping creates a fresh anchor above the
                // selection (the documented `create` contract). ⌘⇧G drives
                // this same path.
                let groupSelectedShortcut = KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
                let groupSelectedLabel = String(
                    localized: "contextMenu.workspaceGroup.newFromSelection",
                    defaultValue: "New Group from Selection"
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
            } else if let target = eligibleTargets.first, target.groupId == nil {
                // Single ungrouped workspace: turn it into a group by making
                // the workspace itself the anchor (no phantom empty anchor).
                // Hidden for workspaces already in a group — those use
                // "Move to Group" / "Remove from Group" below.
                Button(
                    String(
                        localized: "contextMenu.workspaceGroup.newFromWorkspace",
                        defaultValue: "New Group from Workspace"
                    )
                ) {
                    promptWorkspaceGroupFromWorkspace(workspaceId: target.id)
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
        // selectAnchor: false keeps focus on the workspace the user was already
        // in instead of jumping to the new empty group-pivot anchor.
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: workspaceIds, selectAnchor: false)
    }

    func promptWorkspaceGroupFromWorkspace(workspaceId: UUID) {
        tabManager.makeWorkspaceGroupFromWorkspace(anchorWorkspaceId: workspaceId)
    }
}

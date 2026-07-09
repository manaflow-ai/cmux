public import Foundation
public import SwiftUI
public import CmuxSidebar

/// The workspace-group portion of a sidebar row's context menu.
///
/// Offers "New Group from Selection/Workspace", a "Move to Group" submenu over
/// the available groups, and "Remove from Group" when any target is grouped.
/// Every input is an immutable value snapshot or a closure: the owning row
/// precomputes which targets are eligible (group anchors are excluded) and
/// which group, if any, they all already belong to, so this view honors the
/// list snapshot-boundary rule and never reads a live workspace store.
///
/// The view renders nothing when ``eligibleTargetIds`` is empty, matching the
/// legacy section's `if !eligibleTargetIds.isEmpty` guard.
public struct SidebarWorkspaceGroupContextMenuSection: View {
    let groups: [SidebarWorkspaceGroupMenuItem]
    let eligibleTargetIds: [UUID]
    let allTargetsInSameGroupId: UUID?
    let hasAnyGroupedTarget: Bool
    let isMulti: Bool
    let groupSelectedShortcutKey: KeyEquivalent?
    let groupSelectedShortcutModifiers: EventModifiers
    let onNewGroup: ([UUID]) -> Void
    let onMoveToGroup: ([UUID], UUID) -> Void
    let onRemoveFromGroup: ([UUID]) -> Void

    /// Creates the group context-menu section.
    /// - Parameters:
    ///   - groups: Group snapshots offered by the "Move to Group" submenu.
    ///   - eligibleTargetIds: Target workspace ids that are not group anchors;
    ///     the section renders only when this is non-empty.
    ///   - allTargetsInSameGroupId: The group id shared by every eligible
    ///     target, or `nil` when they differ; disables that group's row.
    ///   - hasAnyGroupedTarget: Whether any eligible target is in a group;
    ///     gates the "Remove from Group" button.
    ///   - isMulti: Whether more than one workspace is targeted; selects the
    ///     "from Selection" vs "from Workspace" label.
    ///   - groupSelectedShortcutKey: Key equivalent for the new-group action.
    ///   - groupSelectedShortcutModifiers: Modifiers for the new-group action.
    ///   - onNewGroup: Invoked with the eligible ids to create a new group.
    ///   - onMoveToGroup: Invoked with the eligible ids and a target group id.
    ///   - onRemoveFromGroup: Invoked with the eligible ids to ungroup them.
    public init(
        groups: [SidebarWorkspaceGroupMenuItem],
        eligibleTargetIds: [UUID],
        allTargetsInSameGroupId: UUID?,
        hasAnyGroupedTarget: Bool,
        isMulti: Bool,
        groupSelectedShortcutKey: KeyEquivalent?,
        groupSelectedShortcutModifiers: EventModifiers,
        onNewGroup: @escaping ([UUID]) -> Void,
        onMoveToGroup: @escaping ([UUID], UUID) -> Void,
        onRemoveFromGroup: @escaping ([UUID]) -> Void
    ) {
        self.groups = groups
        self.eligibleTargetIds = eligibleTargetIds
        self.allTargetsInSameGroupId = allTargetsInSameGroupId
        self.hasAnyGroupedTarget = hasAnyGroupedTarget
        self.isMulti = isMulti
        self.groupSelectedShortcutKey = groupSelectedShortcutKey
        self.groupSelectedShortcutModifiers = groupSelectedShortcutModifiers
        self.onNewGroup = onNewGroup
        self.onMoveToGroup = onMoveToGroup
        self.onRemoveFromGroup = onRemoveFromGroup
    }

    public var body: some View {
        if !eligibleTargetIds.isEmpty {
            let groupSelectedLabel = isMulti
                ? String(
                    localized: "contextMenu.workspaceGroup.newFromSelection",
                    defaultValue: "New Group from Selection",
                    bundle: .main
                )
                : String(
                    localized: "contextMenu.workspaceGroup.newFromWorkspace",
                    defaultValue: "New Group from Workspace",
                    bundle: .main
                )
            if let key = groupSelectedShortcutKey {
                Button(groupSelectedLabel) {
                    onNewGroup(eligibleTargetIds)
                }
                .keyboardShortcut(key, modifiers: groupSelectedShortcutModifiers)
            } else {
                Button(groupSelectedLabel) {
                    onNewGroup(eligibleTargetIds)
                }
            }

            Menu(
                String(
                    localized: "contextMenu.workspaceGroup.moveTo",
                    defaultValue: "Move to Group",
                    bundle: .main
                )
            ) {
                ForEach(groups) { group in
                    Button(group.name) {
                        onMoveToGroup(eligibleTargetIds, group.id)
                    }
                    .disabled(allTargetsInSameGroupId == group.id)
                }
            }
            .disabled(groups.isEmpty)

            if hasAnyGroupedTarget {
                Button(
                    String(
                        localized: "contextMenu.workspaceGroup.remove",
                        defaultValue: "Remove from Group",
                        bundle: .main
                    )
                ) {
                    onRemoveFromGroup(eligibleTargetIds)
                }
            }
        }
    }
}

import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// A collapsible group-section header in the mobile workspace list.
///
/// Mirrors the Mac sidebar group header, which doubles as the group's anchor
/// workspace row: the leading disclosure chevron toggles collapse, while tapping
/// the name/body selects (and, in push navigation, opens) the anchor workspace.
/// The anchor is represented by this header and never rendered as a separate row,
/// so this split is what keeps the anchor's terminals reachable from the phone.
struct WorkspaceGroupHeaderRow: View {
    let group: MobileWorkspaceGroupPreview
    /// Aggregate unread state for the header dot, computed by
    /// `MobileWorkspaceListItem.items`: the anchor's unread while expanded,
    /// the whole group's (anchor included) while collapsed, mirroring the Mac
    /// sidebar header badge so collapsing a group never hides activity.
    let hasUnread: Bool
    let navigationStyle: WorkspaceNavigationStyle
    /// Whether the anchor workspace is the current selection (sidebar style only).
    let isAnchorSelected: Bool
    /// Select the anchor workspace in sidebar layouts.
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Create a new workspace inside this group. Hidden when `nil`.
    var createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    /// Rename the group on the Mac. Hidden when `nil`.
    var renameGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? = nil
    /// Pin or unpin the group on the Mac. Hidden when `nil`.
    var setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? = nil
    /// Dissolve the group on the Mac, keeping its workspaces. Hidden when `nil`.
    var ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    /// Delete the group on the Mac, including its workspaces. Hidden when `nil`.
    var deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    /// Toggle the group's collapsed state on the Mac. When `nil` (previews, or a
    /// Mac without the groups capability), the chevron renders without a tap
    /// action.
    let toggleCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift

    @State private var isRenaming = false
    @State private var pendingDestructiveAction: WorkspaceGroupHeaderPendingDestructiveAction?

    /// The leading disclosure chevron. Its own hit target, so tapping it only
    /// collapses/expands and never opens the anchor.
    private var chevron: some View {
        let image = Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())

        // `.isButton` only when there is an actual activation action: a passive
        // chevron (no `toggleCollapsed`) must not announce as a button VoiceOver
        // can press to no effect. The collapsed/expanded state stays readable
        // through the label either way.
        return Group {
            if let toggleCollapsed {
                Button {
                    toggleCollapsed(group.id, !group.isCollapsed)
                } label: {
                    image
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
            } else {
                image
            }
        }
        .accessibilityLabel(
            group.isCollapsed
                ? L10n.string("mobile.workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : L10n.string("mobile.workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        )
        .accessibilityIdentifier("MobileWorkspaceGroupDisclosure-\(group.id.rawValue)")
    }

    /// The group name plus icon. Tapping it opens the anchor workspace, mirroring
    /// the desktop header whose body focuses the anchor.
    private var nameLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(group.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if group.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var anchorTarget: some View {
        switch navigationStyle {
        case .push:
            Button {
                selectWorkspace(group.anchorWorkspaceID)
            } label: {
                nameLabel
            }
            .buttonStyle(.plain)
        case .sidebar:
            Button {
                selectWorkspace(group.anchorWorkspaceID)
            } label: {
                nameLabel
            }
            .buttonStyle(.plain)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Same leading unread gutter as workspace rows (dot hidden when
            // read) so headers and top-level rows keep their columns aligned.
            WorkspaceUnreadDot(isUnread: hasUnread, leftShift: unreadIndicatorLeftShift)
            chevron
            anchorTarget
                // The dot itself is accessibility-hidden; VoiceOver hears the
                // unread state on the anchor target, like workspace rows.
                .accessibilityValue(
                    hasUnread
                        ? L10n.string("mobile.workspace.unread", defaultValue: "Unread")
                        : ""
                )
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            // Sidebar style highlights the active anchor's header, mirroring the
            // desktop header background when its anchor is selected. Push style
            // has no persistent selection, so it stays clear.
            (navigationStyle == .sidebar && isAnchorSelected)
                ? Color.primary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu { contextMenu }
        .sheet(isPresented: $isRenaming) {
            WorkspaceGroupRenameSheet(currentName: group.name) { newName in
                renameGroup?(group.id, newName)
            }
        }
        .confirmationDialog(
            destructiveDialogTitle,
            isPresented: destructiveDialogIsPresented,
            titleVisibility: .visible
        ) {
            if pendingDestructiveAction == .ungroup, let ungroupWorkspaceGroup {
                Button(
                    L10n.string("mobile.workspaceGroup.ungroup.confirmAction", defaultValue: "Ungroup"),
                    role: .destructive
                ) {
                    ungroupWorkspaceGroup(group.id)
                    pendingDestructiveAction = nil
                }
                .accessibilityIdentifier("MobileWorkspaceGroupUngroupConfirmButton-\(group.id.rawValue)")
            }
            if pendingDestructiveAction == .delete, let deleteWorkspaceGroup {
                Button(
                    L10n.string("mobile.workspaceGroup.delete.confirmAction", defaultValue: "Delete Group"),
                    role: .destructive
                ) {
                    deleteWorkspaceGroup(group.id)
                    pendingDestructiveAction = nil
                }
                .accessibilityIdentifier("MobileWorkspaceGroupDeleteConfirmButton-\(group.id.rawValue)")
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingDestructiveAction = nil
            }
        } message: {
            Text(destructiveDialogMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceGroupHeader-\(group.id.rawValue)")
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let setGroupPinned {
            Button {
                setGroupPinned(group.id, !group.isPinned)
            } label: {
                if group.isPinned {
                    Label(L10n.string("mobile.workspaceGroup.unpin", defaultValue: "Unpin Group"), systemImage: "pin.slash")
                } else {
                    Label(L10n.string("mobile.workspaceGroup.pin", defaultValue: "Pin Group"), systemImage: "pin")
                }
            }
            .accessibilityIdentifier("MobileWorkspaceGroupPinButton-\(group.id.rawValue)")
        }
        if renameGroup != nil {
            Button {
                isRenaming = true
            } label: {
                Label(L10n.string("mobile.workspaceGroup.rename.action", defaultValue: "Rename Group"), systemImage: "pencil")
            }
            .accessibilityIdentifier("MobileWorkspaceGroupRenameButton-\(group.id.rawValue)")
        }
        if renameGroup != nil || setGroupPinned != nil {
            Divider()
        }
        if let createWorkspaceInGroup {
            Button {
                createWorkspaceInGroup(group.id)
            } label: {
                Label(
                    L10n.string("mobile.workspaceGroup.newWorkspace", defaultValue: "New Workspace in Group"),
                    systemImage: "plus"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceGroupNewWorkspace-\(group.id.rawValue)")
        }
        if ungroupWorkspaceGroup != nil || deleteWorkspaceGroup != nil {
            Divider()
        }
        if ungroupWorkspaceGroup != nil {
            Button(role: .destructive) {
                pendingDestructiveAction = .ungroup
            } label: {
                Label(
                    L10n.string("mobile.workspaceGroup.ungroup", defaultValue: "Ungroup (Keep Workspaces)"),
                    systemImage: "rectangle.3.group"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceGroupUngroupButton-\(group.id.rawValue)")
        }
        if deleteWorkspaceGroup != nil {
            Button(role: .destructive) {
                pendingDestructiveAction = .delete
            } label: {
                Label(
                    L10n.string("mobile.workspaceGroup.delete", defaultValue: "Delete Group (Close Workspaces)"),
                    systemImage: "trash"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceGroupDeleteButton-\(group.id.rawValue)")
        }
    }

    private var destructiveDialogTitle: String {
        switch pendingDestructiveAction {
        case .ungroup:
            return L10n.string("mobile.workspaceGroup.ungroup.confirmTitle", defaultValue: "Ungroup Group?")
        case .delete:
            return L10n.string("mobile.workspaceGroup.delete.confirmTitle", defaultValue: "Delete Group?")
        case nil:
            return ""
        }
    }

    private var destructiveDialogMessage: String {
        switch pendingDestructiveAction {
        case .ungroup:
            return L10n.string(
                "mobile.workspaceGroup.ungroup.confirmMessage",
                defaultValue: "This will dissolve the group on your Mac and keep its workspaces."
            )
        case .delete:
            return L10n.string(
                "mobile.workspaceGroup.delete.confirmMessage",
                defaultValue: "This will delete the group and close its workspaces on your Mac."
            )
        case nil:
            return ""
        }
    }

    private var destructiveDialogIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDestructiveAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDestructiveAction = nil
                }
            }
        )
    }
}

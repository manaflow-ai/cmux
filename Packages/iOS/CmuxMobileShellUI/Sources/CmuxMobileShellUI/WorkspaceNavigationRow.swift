import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let wrapWorkspaceTitles: Bool
    /// How many lines the activity preview shows (1 or 2), forwarded to the
    /// shared ``WorkspaceRow``.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    var profilePictureLeftShift: Double = MobileDisplaySettings.defaultProfilePictureLeftShift
    var profilePictureSize: Double = MobileDisplaySettings.defaultProfilePictureSize
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Rename the workspace on the Mac. When `nil` (e.g. previews) the rename
    /// affordance is hidden.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)? = nil
    /// Pin or unpin the workspace on the Mac. When `nil` the pin affordance is
    /// hidden.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil
    /// Mark the workspace read or unread on the Mac. When `nil` the read-state
    /// affordance is hidden.
    var setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil
    /// Close the workspace on the Mac. When `nil` the delete affordance is
    /// hidden.
    var closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil

    @State private var isRenaming = false

    var body: some View {
        rowTarget
        .contextMenu { contextMenu }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let setUnread {
                Button {
                    setUnread(workspace.id, !workspace.hasUnread)
                } label: {
                    Label(readStateActionTitle, systemImage: readStateActionSystemImage)
                }
                .tint(.blue)
                .accessibilityIdentifier("MobileWorkspaceReadStateSwipeButton-\(workspace.id.rawValue)")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let closeWorkspace {
                Button {
                    closeWorkspace(workspace.id)
                } label: {
                    Label(L10n.string("mobile.workspace.delete", defaultValue: "Delete"), systemImage: "trash")
                }
                .tint(.red)
                .accessibilityIdentifier("MobileWorkspaceDeleteSwipeButton-\(workspace.id.rawValue)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.accessibilitySummary(connectionStatus: connectionStatus))
        .sheet(isPresented: $isRenaming) {
            WorkspaceRenameSheet(currentName: workspace.name) { newName in
                renameWorkspace?(workspace.id, newName)
            }
        }
    }

    @ViewBuilder
    private var rowTarget: some View {
        switch navigationStyle {
        case .push:
            Button {
                selectWorkspace(workspace.id)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        case .sidebar:
            Button {
                selectWorkspace(workspace.id)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var rowLabel: some View {
        WorkspaceRow(
            workspace: workspace,
            connectionStatus: connectionStatus,
            isSelected: navigationStyle == .sidebar && isSelected,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            profilePictureLeftShift: profilePictureLeftShift,
            profilePictureSize: profilePictureSize
        )
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let setPinned {
            Button {
                setPinned(workspace.id, !workspace.isPinned)
            } label: {
                if workspace.isPinned {
                    Label(L10n.string("mobile.workspace.unpin", defaultValue: "Unpin"), systemImage: "pin.slash")
                } else {
                    Label(L10n.string("mobile.workspace.pin", defaultValue: "Pin"), systemImage: "pin")
                }
            }
            .accessibilityIdentifier("MobileWorkspacePinButton-\(workspace.id.rawValue)")
        }
        if renameWorkspace != nil {
            Button {
                isRenaming = true
            } label: {
                Label(L10n.string("mobile.workspace.rename.action", defaultValue: "Rename"), systemImage: "pencil")
            }
            .accessibilityIdentifier("MobileWorkspaceRenameButton-\(workspace.id.rawValue)")
        }
        if let setUnread {
            Button {
                setUnread(workspace.id, !workspace.hasUnread)
            } label: {
                Label(readStateActionTitle, systemImage: readStateActionSystemImage)
            }
            .accessibilityIdentifier("MobileWorkspaceReadStateMenuButton-\(workspace.id.rawValue)")
        }
        if let closeWorkspace {
            Button(role: .destructive) {
                closeWorkspace(workspace.id)
            } label: {
                Label(L10n.string("mobile.workspace.delete", defaultValue: "Delete"), systemImage: "trash")
            }
            .accessibilityIdentifier("MobileWorkspaceDeleteMenuButton-\(workspace.id.rawValue)")
        }
    }

    private var readStateActionTitle: String {
        workspace.hasUnread
            ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
            : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread")
    }

    private var readStateActionSystemImage: String {
        workspace.hasUnread ? "envelope.open" : "envelope.badge"
    }
}

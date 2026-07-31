import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    /// Immutable changes summary projected by ``WorkspaceListView`` above `List`.
    var changesChip: MobileWorkspaceChangesChip? = nil
    /// Opens the immutable changes snapshot's workspace without selecting this row.
    var onOpenChanges: (@MainActor () -> Void)? = nil
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let wrapWorkspaceTitles: Bool
    /// How many lines the activity preview shows (1 or 2), forwarded to the
    /// shared ``WorkspaceRow``.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Rename the workspace on the Mac. When `nil` (e.g. previews) the rename
    /// affordance is hidden.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)? = nil
    /// Customize the workspace's name, description, color, and pin state on the Mac.
    var customizeWorkspace: WorkspaceCustomizationAction? = nil
    /// Pin or unpin the workspace on the Mac. When `nil` the pin affordance is
    /// hidden.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil
    /// Mark the workspace read or unread on the Mac. When `nil` the read-state
    /// affordance is hidden.
    var setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil
    /// Close the workspace on the Mac. When `nil` the delete affordance is
    /// hidden.
    var closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil
    /// Whether this row's destructive close action is awaiting confirmation.
    /// The binding is owned by the list so recycled rows do not own presentation
    /// state, but the presenter stays attached to the swiped row.
    var isConfirmingClose: Binding<Bool> = .constant(false)
    /// Performs the confirmed close. Separate from ``closeWorkspace`` so a
    /// full-swipe can request confirmation without directly closing the row.
    var confirmCloseWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil

    @State private var isRenaming = false
    @State private var isCustomizing = false

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
        .accessibilityElement(children: onOpenChanges == nil ? .combine : .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityValue(workspace.accessibilitySummary(connectionStatus: connectionStatus))
        .accessibilityActions {
            if customizeWorkspace != nil {
                Button(L10n.string("mobile.workspace.customize.action", defaultValue: "Customize")) {
                    isCustomizing = true
                }
            } else if renameWorkspace != nil {
                Button(L10n.string("mobile.workspace.rename.action", defaultValue: "Rename")) {
                    isRenaming = true
                }
            }
            if let setPinned {
                Button(
                    workspace.isPinned
                        ? L10n.string("mobile.workspace.unpin", defaultValue: "Unpin")
                        : L10n.string("mobile.workspace.pin", defaultValue: "Pin")
                ) {
                    setPinned(workspace.id, !workspace.isPinned)
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            WorkspaceRenameSheet(currentName: workspace.name) { newName in
                renameWorkspace?(workspace.id, newName)
            }
        }
        .sheet(isPresented: $isCustomizing) {
            WorkspaceCustomizationSheet(workspace: workspace) { initialDraft, submittedDraft in
                await customizeWorkspace?(workspace.id, initialDraft, submittedDraft) ?? .failure()
            }
        }
        .confirmationDialog(
            L10n.string("mobile.workspace.delete.confirmTitle", defaultValue: "Delete Workspace?"),
            isPresented: isConfirmingClose,
            titleVisibility: .visible
        ) {
            if let confirmCloseWorkspace {
                Button(L10n.string("mobile.workspace.delete.confirmAction", defaultValue: "Delete"), role: .destructive) {
                    confirmCloseWorkspace(workspace.id)
                }
                .accessibilityIdentifier("MobileWorkspaceDeleteConfirmButton-\(workspace.id.rawValue)")
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                isConfirmingClose.wrappedValue = false
            }
        } message: {
            Text(L10n.string("mobile.workspace.delete.confirmMessage", defaultValue: "This will close the workspace on your Mac."))
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
        // The chip renders inside WorkspaceRow so the UIKit table pipeline
        // (which hosts WorkspaceRow directly) shows the same signifier.
        WorkspaceRow(
            workspace: workspace,
            connectionStatus: connectionStatus,
            isSelected: navigationStyle == .sidebar && isSelected,
            changesChip: changesChip,
            onOpenChanges: onOpenChanges,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift
        )
    }

    private var rowAccessibilityLabel: String {
        // An interactive chip is exposed as its own accessibility button, so
        // the row must not repeat the same changes summary.
        guard onOpenChanges == nil else { return workspace.name }
        guard let changesChip, changesChip.filesChanged > 0 else { return workspace.name }
        return String(
            format: String(
                localized: "workspace.changes.chip.row_accessibility",
                defaultValue: "%1$@, %2$lld additions, %3$lld deletions",
                bundle: .module
            ),
            workspace.name,
            changesChip.additions,
            changesChip.deletions
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
        if customizeWorkspace != nil {
            Button {
                isCustomizing = true
            } label: {
                Label(
                    L10n.string("mobile.workspace.customize.action", defaultValue: "Customize"),
                    systemImage: "slider.horizontal.3"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceCustomizeButton-\(workspace.id.rawValue)")
        } else if renameWorkspace != nil {
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

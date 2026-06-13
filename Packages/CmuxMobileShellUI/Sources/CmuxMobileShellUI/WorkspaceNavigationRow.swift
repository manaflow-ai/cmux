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
    /// Whether this row's destructive close action is awaiting confirmation.
    /// The binding is owned by the list so recycled rows do not own presentation
    /// state, but the presenter stays attached to the swiped row.
    var isConfirmingClose: Binding<Bool> = .constant(false)
    /// Performs the confirmed close. Separate from ``closeWorkspace`` so a
    /// full-swipe can request confirmation without directly closing the row.
    var confirmCloseWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil

    @State private var isRenaming = false
    @State private var deleteSwipeOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            if closeWorkspace != nil {
                deleteActionTray
            }

            WorkspaceRow(
                workspace: workspace,
                connectionStatus: connectionStatus,
                isSelected: navigationStyle == .sidebar && isSelected,
                wrapWorkspaceTitles: wrapWorkspaceTitles,
                previewLineLimit: previewLineLimit
            )
            .background(Color(.systemBackground))
            .offset(x: rowOffset)
        }
        .animation(.snappy(duration: 0.22), value: isConfirmingClose.wrappedValue)
        .animation(.snappy(duration: 0.22), value: deleteSwipeOffset)
        .clipShape(Rectangle())
        .onTapGesture {
            if isConfirmingClose.wrappedValue {
                isConfirmingClose.wrappedValue = false
            } else {
                selectWorkspace(workspace.id)
            }
        }
        .simultaneousGesture(deleteSwipeGesture)
        .contentShape(Rectangle())
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
        .onChange(of: isConfirmingClose.wrappedValue) { _, isPresented in
            if !isPresented {
                deleteSwipeOffset = 0
            }
        }
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

    private var rowOffset: CGFloat {
        if isConfirmingClose.wrappedValue {
            return -Self.deleteConfirmationWidth
        }
        return deleteSwipeOffset
    }

    private var deleteSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard closeWorkspace != nil else {
                    return
                }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), horizontal < 0 else {
                    return
                }
                isConfirmingClose.wrappedValue = false
                deleteSwipeOffset = max(-Self.deleteConfirmationWidth, horizontal)
            }
            .onEnded { value in
                guard closeWorkspace != nil else {
                    deleteSwipeOffset = 0
                    return
                }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), horizontal < 0 else {
                    deleteSwipeOffset = 0
                    return
                }
                if horizontal <= -Self.deleteConfirmationThreshold {
                    closeWorkspace?(workspace.id)
                    deleteSwipeOffset = -Self.deleteConfirmationWidth
                } else if horizontal <= -Self.deleteRevealThreshold {
                    deleteSwipeOffset = -Self.deleteRevealWidth
                } else {
                    deleteSwipeOffset = 0
                }
            }
    }

    private var deleteActionTray: some View {
        HStack(spacing: 0) {
            if isConfirmingClose.wrappedValue {
                Button {
                    isConfirmingClose.wrappedValue = false
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "xmark")
                            .font(.headline)
                        Text(L10n.string("mobile.common.cancel", defaultValue: "Cancel"))
                            .font(.caption2)
                    }
                    .frame(width: Self.deleteCancelWidth)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.secondary)
                .accessibilityIdentifier("MobileWorkspaceDeleteCancelButton-\(workspace.id.rawValue)")
            }

            Button(role: .destructive) {
                if isConfirmingClose.wrappedValue {
                    confirmCloseWorkspace?(workspace.id)
                } else {
                    closeWorkspace?(workspace.id)
                    deleteSwipeOffset = -Self.deleteConfirmationWidth
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.headline)
                    Text(L10n.string("mobile.workspace.delete", defaultValue: "Delete"))
                        .font(.caption2)
                }
                .frame(width: isConfirmingClose.wrappedValue ? Self.deleteConfirmWidth : Self.deleteRevealWidth)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.red)
            .accessibilityIdentifier("MobileWorkspaceDeleteSwipeButton-\(workspace.id.rawValue)")
        }
        .frame(width: isConfirmingClose.wrappedValue ? Self.deleteConfirmationWidth : Self.deleteRevealWidth)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var readStateActionTitle: String {
        workspace.hasUnread
            ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
            : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread")
    }

    private var readStateActionSystemImage: String {
        workspace.hasUnread ? "envelope.open" : "envelope.badge"
    }

    private static let deleteRevealWidth: CGFloat = 88
    private static let deleteCancelWidth: CGFloat = 88
    private static let deleteConfirmWidth: CGFloat = 88
    private static let deleteConfirmationWidth = deleteCancelWidth + deleteConfirmWidth
    private static let deleteRevealThreshold: CGFloat = 44
    private static let deleteConfirmationThreshold: CGFloat = 132
}

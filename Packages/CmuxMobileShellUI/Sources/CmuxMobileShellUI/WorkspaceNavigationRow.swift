import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let wrapWorkspaceTitles: Bool
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Rename the workspace on the Mac. When `nil` (e.g. previews) the rename
    /// affordance is hidden.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Pin or unpin the workspace on the Mac. When `nil` the pin affordance is
    /// hidden.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Mark the workspace read or unread on the Mac. When `nil` the read/unread
    /// affordance is hidden.
    var setRead: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Delete the workspace on the Mac. When `nil` the destructive swipe
    /// affordance is hidden.
    var deleteWorkspace: ((MobileWorkspacePreview.ID) -> Void)?

    @State private var isRenaming = false

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(
                        workspace: workspace,
                        connectionStatus: connectionStatus,
                        isSelected: false,
                        wrapWorkspaceTitles: wrapWorkspaceTitles
                    )
                }
                .simultaneousGesture(TapGesture().onEnded {
                    selectWorkspace(workspace.id)
                })
            case .sidebar:
                Button {
                    selectWorkspace(workspace.id)
                } label: {
                    WorkspaceRow(
                        workspace: workspace,
                        connectionStatus: connectionStatus,
                        isSelected: isSelected,
                        wrapWorkspaceTitles: wrapWorkspaceTitles
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { contextMenu }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            readSwipeAction
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Delete is declared first so it stays the full-swipe action; Pin is
            // a deliberate tap so a careless full swipe can never pin/unpin.
            deleteSwipeAction
            pinSwipeAction
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

    /// Leading swipe: mark the workspace read or unread, mirroring the Mac's
    /// unread indicator so the direction always matches current state.
    @ViewBuilder
    private var readSwipeAction: some View {
        if let setRead {
            Button {
                setRead(workspace.id, workspace.hasUnread)
            } label: {
                if workspace.hasUnread {
                    Label(
                        L10n.string("mobile.workspace.markRead", defaultValue: "Read"),
                        systemImage: "envelope.open"
                    )
                } else {
                    Label(
                        L10n.string("mobile.workspace.markUnread", defaultValue: "Unread"),
                        systemImage: "envelope.badge"
                    )
                }
            }
            .tint(.blue)
            .accessibilityIdentifier("MobileWorkspaceMarkReadButton-\(workspace.id.rawValue)")
        }
    }

    /// Trailing swipe: pin or unpin the workspace.
    @ViewBuilder
    private var pinSwipeAction: some View {
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
            .tint(.orange)
            .accessibilityIdentifier("MobileWorkspacePinSwipeButton-\(workspace.id.rawValue)")
        }
    }

    /// Trailing swipe: destructively delete the workspace (full-swipe target).
    @ViewBuilder
    private var deleteSwipeAction: some View {
        if let deleteWorkspace {
            Button(role: .destructive) {
                deleteWorkspace(workspace.id)
            } label: {
                Label(L10n.string("mobile.common.delete", defaultValue: "Delete"), systemImage: "trash")
            }
            .tint(.red)
            .accessibilityIdentifier("MobileWorkspaceDeleteButton-\(workspace.id.rawValue)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let setRead {
            Button {
                setRead(workspace.id, workspace.hasUnread)
            } label: {
                if workspace.hasUnread {
                    Label(
                        L10n.string("mobile.workspace.markRead", defaultValue: "Read"),
                        systemImage: "envelope.open"
                    )
                } else {
                    Label(
                        L10n.string("mobile.workspace.markUnread", defaultValue: "Unread"),
                        systemImage: "envelope.badge"
                    )
                }
            }
            .accessibilityIdentifier("MobileWorkspaceMarkReadMenuButton-\(workspace.id.rawValue)")
        }
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
    }
}

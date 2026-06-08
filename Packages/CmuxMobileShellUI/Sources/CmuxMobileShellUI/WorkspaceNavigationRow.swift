import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct WorkspaceNavigationRow: View {
    let workspace: MobileWorkspacePreview
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let isSelected: Bool
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    /// Rename the workspace on the Mac. When `nil` (e.g. previews) the rename
    /// affordance is hidden.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Pin or unpin the workspace on the Mac. When `nil` the pin affordance is
    /// hidden.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?

    @State private var isRenaming = false

    var body: some View {
        Group {
            switch navigationStyle {
            case .push:
                NavigationLink(value: workspace.id) {
                    WorkspaceRow(workspace: workspace, host: host, connectionStatus: connectionStatus, isSelected: false)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    selectWorkspace(workspace.id)
                })
            case .sidebar:
                Button {
                    selectWorkspace(workspace.id)
                } label: {
                    WorkspaceRow(workspace: workspace, host: host, connectionStatus: connectionStatus, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
        .accessibilityLabel(workspace.name)
        .accessibilityValue(workspace.accessibilitySummary(host: host, connectionStatus: connectionStatus))
        .sheet(isPresented: $isRenaming) {
            WorkspaceRenameSheet(currentName: workspace.name) { newName in
                renameWorkspace?(workspace.id, newName)
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
    }
}

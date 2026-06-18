#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// DEBUG-only workspace list fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`.
/// It exercises the production `WorkspaceListView` and row components with a
/// static unread row, avoiding auth and Mac pairing while keeping layout code
/// identical to the real shell.
struct WorkspaceListLayoutPreviewView: View {
    @State private var selectedWorkspaceID: MobileWorkspacePreview.ID?

    private let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-ios",
            name: "iOS avatar tuning",
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-ios", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
        ),
    ]

    var body: some View {
        NavigationStack {
            WorkspaceListView(
                workspaces: workspaces,
                selectedWorkspaceID: selectedWorkspaceID,
                host: "Visual Mock Mac",
                connectionStatus: .connected,
                navigationStyle: .push,
                wrapWorkspaceTitles: false,
                previewLineLimit: MobileDisplaySettings.defaultWorkspacePreviewLineCount,
                unreadIndicatorLeftShift: MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
                profilePictureLeftShift: MobileDisplaySettings.defaultProfilePictureLeftShift,
                profilePictureSize: MobileDisplaySettings.defaultProfilePictureSize,
                selectWorkspace: { selectedWorkspaceID = $0 },
                createWorkspace: {}
            )
        }
    }
}
#endif

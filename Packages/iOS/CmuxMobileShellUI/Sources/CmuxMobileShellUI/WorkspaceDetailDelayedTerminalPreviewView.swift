import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

#if os(iOS) && DEBUG
struct WorkspaceDetailDelayedTerminalPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-delayed-terminal")
    private static let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-delayed")

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: .connected,
        connectedHostName: "UI Test Mac",
        workspaces: [
            MobileWorkspacePreview(
                id: workspaceID,
                name: "New Workspace",
                terminals: []
            ),
        ]
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var didInjectTerminal = false

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil
        )
        .environment(browserStore)
        .task {
            guard !didInjectTerminal else { return }
            didInjectTerminal = true
            store.selectedWorkspaceID = Self.workspaceID
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let workspace = MobileWorkspacePreview(
                id: Self.workspaceID,
                name: "New Workspace",
                terminals: [
                    MobileTerminalPreview(id: Self.terminalID, name: "Terminal 1"),
                ]
            )
            store.setWorkspacesForTesting([workspace])
            store.selectedWorkspaceID = Self.workspaceID
            store.selectedTerminalID = Self.terminalID
        }
    }
}
#endif

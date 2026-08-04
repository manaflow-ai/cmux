#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

/// Interactive CMUX Labs workspace that renders each redesign against the same
/// three-terminal snapshot without requiring a paired Mac.
struct WorkspaceDetailLabPreviewView: View {
    private static let workspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-detail-lab")
    private static let buildTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-labs-build")

    @Environment(\.dismiss) private var dismiss
    @State private var store = makeStore()
    @State private var browserStore = BrowserSurfaceStore()
    @State private var browserStreamStore = BrowserStreamStore()

    var body: some View {
        Group {
            if let workspace = store.workspaces.first {
                WorkspaceDetailView(
                    host: "",
                    connectionStatus: .connected,
                    workspace: workspace,
                    store: store,
                    createWorkspace: {},
                    canCreateWorkspace: true,
                    createTerminal: createTerminal,
                    renameWorkspace: { _, name in updateWorkspace { $0.name = name } },
                    customizeWorkspace: { _, _, draft in
                        updateWorkspace {
                            $0.name = draft.name
                            $0.customDescription = draft.customDescription
                            $0.customColorHex = draft.customColorHex
                            $0.isPinned = draft.isPinned
                        }
                        return .success
                    },
                    setWorkspaceUnread: { _, isUnread in
                        updateWorkspace { $0.hasUnread = isUnread }
                    },
                    closeWorkspace: { _ in },
                    reportTerminalViewport: { _, _, _ in },
                    sendTerminalInput: { _ in },
                    safeAreaContext: .fullWidth,
                    backButtonConfiguration: WorkspaceBackButtonConfiguration(
                        unreadCount: 0,
                        badgeContrast: .darkBackground,
                        action: { dismiss() }
                    ),
                    signOut: nil
                )
            }
        }
        .environment(browserStore)
        .environment(browserStreamStore)
        .navigationBarBackButtonHidden(true)
        .accessibilityIdentifier("MobileWorkspaceDetailLabPreview")
    }

    private static func makeStore() -> MobileShellComposite {
        var workspace = MobileWorkspacePreview(
            id: workspaceID,
            name: L10n.string(
                "mobile.settings.workspaceDetailLab.preview.workspace",
                defaultValue: "Workspace Detail Lab"
            ),
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(
                    id: buildTerminalID,
                    name: L10n.string(
                        "mobile.settings.workspaceDetailLab.preview.build",
                        defaultValue: "Build"
                    )
                ),
                MobileTerminalPreview(
                    id: "terminal-labs-tests",
                    name: L10n.string(
                        "mobile.settings.workspaceDetailLab.preview.tests",
                        defaultValue: "Tests"
                    )
                ),
                MobileTerminalPreview(
                    id: "terminal-labs-server",
                    name: L10n.string(
                        "mobile.settings.workspaceDetailLab.preview.server",
                        defaultValue: "Dev Server"
                    )
                ),
            ]
        )
        workspace.actionCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: true,
            supportsReadStateActions: true,
            supportsCloseActions: true
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            connectionState: .connected,
            connectedHostName: "",
            workspaces: [workspace]
        )
        store.selectedWorkspaceID = workspaceID
        store.selectedTerminalID = buildTerminalID
        return store
    }

    private func createTerminal() {
        let nextIndex = (store.workspaces.first?.terminals.count ?? 0) + 1
        let terminalID = MobileTerminalPreview.ID(rawValue: "terminal-labs-\(nextIndex)")
        updateWorkspace { workspace in
            workspace.terminals.append(MobileTerminalPreview(
                id: terminalID,
                name: String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.settings.workspaceDetailLab.preview.terminalFormat",
                        defaultValue: "Terminal %d"
                    ),
                    nextIndex
                )
            ))
        }
        store.selectedTerminalID = terminalID
    }

    private func updateWorkspace(_ update: (inout MobileWorkspacePreview) -> Void) {
        guard var workspace = store.workspaces.first else { return }
        update(&workspace)
        store.replaceForegroundWorkspaceState([workspace])
        store.selectedWorkspaceID = workspace.id
    }
}
#endif

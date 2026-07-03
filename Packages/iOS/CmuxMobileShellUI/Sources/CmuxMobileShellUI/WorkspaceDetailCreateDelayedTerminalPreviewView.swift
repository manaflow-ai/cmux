import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

#if os(iOS) && DEBUG
struct WorkspaceDetailCreateDelayedTerminalPreviewView: View {
    private static let initialWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-main")
    private static let initialTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-build")
    private static let actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsWorkspaceActions: true,
        supportsReadStateActions: true
    )

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: .connected,
        connectedHostName: "UI Test Mac",
        workspaces: [
            Self.workspace(
                id: initialWorkspaceID,
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(id: initialTerminalID, name: "Build"),
                ]
            ),
            Self.workspace(
                id: "workspace-docs",
                name: "Docs",
                terminals: [
                    MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
                ]
            ),
        ]
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var delayedTerminalTask: Task<Void, Never>?

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil
        )
        .environment(browserStore)
        .task {
            store.selectedWorkspaceID = Self.initialWorkspaceID
            store.selectedTerminalID = Self.initialTerminalID
        }
        .onChange(of: store.selectedWorkspaceID) { _, workspaceID in
            scheduleDelayedTerminalInjection(for: workspaceID)
        }
        .onDisappear {
            delayedTerminalTask?.cancel()
        }
    }

    private func scheduleDelayedTerminalInjection(for workspaceID: MobileWorkspacePreview.ID?) {
        delayedTerminalTask?.cancel()
        guard let workspaceID,
              workspaceID != Self.initialWorkspaceID,
              let workspace = store.workspaces.first(where: { $0.id == workspaceID }),
              workspace.terminals.isEmpty else {
            return
        }
        delayedTerminalTask = Task { @MainActor in
            try? await ContinuousClock().sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            let terminalID = MobileTerminalPreview.ID(rawValue: "\(workspaceID.rawValue)-terminal-1")
            let updatedWorkspace = Self.workspace(
                id: workspace.id,
                macDeviceID: workspace.macDeviceID,
                macDisplayName: workspace.macDisplayName,
                windowID: workspace.windowID,
                name: workspace.name,
                isPinned: workspace.isPinned,
                groupID: workspace.groupID,
                previewText: workspace.previewText,
                previewAt: workspace.previewAt,
                lastActivityAt: workspace.lastActivityAt,
                hasUnread: workspace.hasUnread,
                terminals: [
                    MobileTerminalPreview(id: terminalID, name: "Terminal 1"),
                ]
            )
            let workspaces = store.workspaces.map { existing in
                existing.id == workspaceID ? updatedWorkspace : existing
            }
            store.replaceForegroundWorkspaceState(workspaces)
            store.selectedWorkspaceID = workspaceID
            store.selectedTerminalID = terminalID
        }
    }

    private static func workspace(
        id: MobileWorkspacePreview.ID,
        macDeviceID: String? = nil,
        macDisplayName: String? = nil,
        windowID: String? = nil,
        name: String,
        isPinned: Bool = false,
        groupID: MobileWorkspaceGroupPreview.ID? = nil,
        previewText: String? = nil,
        previewAt: Date? = nil,
        lastActivityAt: Date? = nil,
        hasUnread: Bool = false,
        terminals: [MobileTerminalPreview]
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: id,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            windowID: windowID,
            name: name,
            isPinned: isPinned,
            groupID: groupID,
            previewText: previewText,
            previewAt: previewAt,
            lastActivityAt: lastActivityAt,
            hasUnread: hasUnread,
            terminals: terminals
        )
        workspace.actionCapabilities = actionCapabilities
        return workspace
    }
}
#endif

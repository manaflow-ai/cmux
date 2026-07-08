import CMUXMobileCore
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import SwiftUI

#if os(iOS) && DEBUG
struct WorkspaceDetailCreateDelayedTerminalPreviewView: View {
    private static let initialWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-main")
    private static let initialTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-build")

    @State private var store = MobileShellComposite(
        isSignedIn: true,
        connectionState: .connected,
        connectedHostName: "UI Test Mac",
        workspaces: [
            MobileWorkspacePreview(
                id: initialWorkspaceID,
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(id: initialTerminalID, name: "Build"),
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
    )
    @State private var browserStore = BrowserSurfaceStore()
    @State private var delayedTerminalTask: Task<Void, Never>?
    private let telemetryConsentStore = MobileTelemetryConsentStore(
        defaults: UserDefaults(suiteName: "WorkspaceDetailCreateDelayedTerminalPreviewView.telemetry")!
    )

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: {},
            showAddDevice: nil,
            telemetryConsentStore: telemetryConsentStore
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
            let updatedWorkspace = MobileWorkspacePreview(
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
}
#endif

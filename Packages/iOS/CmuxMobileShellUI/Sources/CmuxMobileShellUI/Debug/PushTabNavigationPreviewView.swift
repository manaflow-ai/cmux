#if os(iOS) && DEBUG
import CmuxMobileBrowser
import CmuxMobileBrowserStream
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

/// A deterministic harness for the push deep-link path.
///
/// This mounts the production `WorkspaceShellView` with a real shell store. The
/// buttons only stand in for APNs delivery and a Mac snapshot: the notification
/// tap itself goes through `MobilePushCoordinator`, and the selected workspace
/// and terminal are rendered by the same navigation stack as the app.
public struct PushTabNavigationPreviewView: View {
    private static let homeWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-home")
    private static let docsWorkspaceID = MobileWorkspacePreview.ID(rawValue: "workspace-docs")
    private static let notesTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-notes")
    private static let closedTerminalID = MobileTerminalPreview.ID(rawValue: "terminal-closed")

    @State private var store: CMUXMobileShellStore
    @Environment(MobilePushCoordinator.self) private var coordinator
    @State private var actionDescription = L10n.string(
        "mobile.push.preview.ready",
        defaultValue: "Ready for a notification tap"
    )
    @State private var targetState: PushTabNavigationPreviewTargetState = .home

    private let browserStore = BrowserSurfaceStore()
    private let browserStreamStore = BrowserStreamStore()
    private let simulatorStreamStore = MobileSimulatorStreamStore()

    /// Creates the deterministic push-navigation preview fixture.
    @MainActor public init() {
        _store = State(initialValue: makePushTabNavigationPreviewStore(connectionState: .disconnected))
    }

    /// Renders the production shell and the fixture controls.
    public var body: some View {
        ZStack(alignment: .top) {
            WorkspaceShellView(
                store: store,
                signOut: {},
                isInitialConnectionLoading: false,
                initialConnectionTimedOut: false,
                retryInitialConnection: nil,
                showAddDevice: nil,
                showPairingScanner: nil,
                showSettings: {},
                showComputers: {}
            )
            .environment(browserStore)
            .environment(browserStreamStore)
            .environment(simulatorStreamStore)
            .pushTabNavigationPresentation(coordinator: coordinator)

            VStack(spacing: 10) {
                Text(L10n.string(
                    "mobile.push.preview.title",
                    defaultValue: "Notification tab navigation"
                ))
                .font(.headline)
                .accessibilityIdentifier("PushTabNavigationTitle")

                Text(actionDescription)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("PushTabNavigationState")

                Text(L10n.string(
                    "mobile.push.preview.currentScreen",
                    defaultValue: "Current screen: \(targetState.targetLabel)"
                ))
                    .font(.caption)
                    .accessibilityIdentifier("PushTabNavigationSelection")

                HStack(spacing: 8) {
                    Button(L10n.string(
                        "mobile.push.preview.tapConnected",
                        defaultValue: "Tap notification for Notes"
                    )) {
                        actionDescription = L10n.string(
                            "mobile.push.preview.waiting",
                            defaultValue: "Waiting for the Mac connection…"
                        )
                        coordinator.handleTap(
                            workspaceId: "workspace-docs",
                            surfaceId: Self.notesTerminalID.rawValue
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("PushTabTapButton")

                    Button(L10n.string(
                        "mobile.push.preview.reconnect",
                        defaultValue: "Reconnect Mac"
                    )) {
                        connectMac()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("PushReconnectButton")
                }

                HStack(spacing: 8) {
                    Button(L10n.string(
                        "mobile.push.preview.tapMissing",
                        defaultValue: "Tap notification for closed tab"
                    )) {
                        removeTargetTab()
                        actionDescription = L10n.string(
                            "mobile.push.preview.missing",
                            defaultValue: "The notification targets a closed tab"
                        )
                        coordinator.handleTap(
                            workspaceId: "workspace-docs",
                            surfaceId: Self.closedTerminalID.rawValue
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("PushMissingTabButton")

                    Button(L10n.string(
                        "mobile.push.preview.tapMissingWorkspace",
                        defaultValue: "Tap notification for closed workspace"
                    )) {
                        removeTargetWorkspace()
                        actionDescription = L10n.string(
                            "mobile.push.preview.missingWorkspace",
                            defaultValue: "The notification targets a closed workspace"
                        )
                        coordinator.handleTap(
                            workspaceId: "workspace-gone",
                            surfaceId: Self.notesTerminalID.rawValue
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("PushMissingWorkspaceButton")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .zIndex(2)
        }
        .onAppear {
            coordinator.bind(store: store)
        }
        .onChange(of: store.selectedWorkspaceID) { _, workspaceID in
            updateOpenedTargetIfNeeded(workspaceID: workspaceID)
        }
        .onChange(of: store.selectedTerminalID) { _, _ in
            updateOpenedTargetIfNeeded(workspaceID: store.selectedWorkspaceID)
        }
    }

    private func updateOpenedTargetIfNeeded(workspaceID: MobileWorkspacePreview.ID?) {
        guard workspaceID == Self.docsWorkspaceID,
              store.selectedTerminalID == Self.notesTerminalID else { return }
        targetState = .connected
        actionDescription = L10n.string(
            "mobile.push.preview.opened",
            defaultValue: "Opened Notes from the notification"
        )
    }

    private func connectMac() {
        store.replaceForegroundWorkspaceState(connectedWorkspaces)
        store.connectPreviewHost()
        coordinator.workspacesDidChange()
        actionDescription = L10n.string(
            "mobile.push.preview.connected",
            defaultValue: "Mac connection active"
        )
    }

    private func removeTargetTab() {
        store.replaceForegroundWorkspaceState(connectedWorkspaces.map { workspace in
            guard workspace.id == Self.docsWorkspaceID else { return workspace }
            var copy = workspace
            copy.terminals = []
            return copy
        })
        targetState = .missingTab
        coordinator.workspacesDidChange()
    }

    private func removeTargetWorkspace() {
        store.replaceForegroundWorkspaceState([
            Self.homeWorkspace
        ])
        targetState = .missingWorkspace
        coordinator.workspacesDidChange()
    }

    private static var homeWorkspace: MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: homeWorkspaceID,
            name: "Home",
            terminals: [
                MobileTerminalPreview(id: "terminal-home", name: "Shell")
            ]
        )
    }

    private static var docsWorkspace: MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: docsWorkspaceID,
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: notesTerminalID, name: "Notes")
            ]
        )
    }

    private var connectedWorkspaces: [MobileWorkspacePreview] {
        [Self.homeWorkspace, Self.docsWorkspace]
    }
}

@MainActor private func makePushTabNavigationPreviewStore(
    connectionState: MobileConnectionState
) -> CMUXMobileShellStore {
    CMUXMobileShellStore(
        isSignedIn: true,
        connectionState: connectionState,
        pairingCode: "preview",
        workspaces: [
            MobileWorkspacePreview(
                id: "workspace-home",
                name: "Home",
                terminals: []
            )
        ]
    )
}

private extension View {
    func pushTabNavigationPresentation(
        coordinator: MobilePushCoordinator
    ) -> some View {
        mobilePushAlertPresentation(coordinator: coordinator)
    }
}
#endif

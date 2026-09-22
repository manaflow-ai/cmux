#if os(iOS) && DEBUG
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
import SwiftUI

private actor PushTabNavigationPreviewRegistration: PushRegistering {
    var isEnabled: Bool { false }
    var snapshot: PushRegistrationSnapshot { .disabled }

    func snapshots() async -> AsyncStream<PushRegistrationSnapshot> {
        AsyncStream { continuation in
            continuation.yield(.disabled)
            continuation.finish()
        }
    }

    func setEnabled(_ enabled: Bool) async {}
    func applyEnabledIntent(_ enabled: Bool, generation: UInt64) async {}
    func reconcileEnabledIntent(generation: UInt64) async {}
    func register(deviceToken: Data) async {}
    func deviceTokenRegistrationFailed() async {}
    func syncTokenIfPossible() async {}
    func unregisterFromServer() async {}
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async {}
    func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async {}
}

/// Deterministic end-to-end fixture for APNs tab navigation. It drives the
/// production coordinator through the same parked-tap, reconnect, and missing
/// surface paths used by the app delegate.
public struct PushTabNavigationPreviewView: View {
    @State private var store: CMUXMobileShellStore
    @State private var coordinator: MobilePushCoordinator
    @State private var actionDescription = L10n.string(
        "mobile.push.preview.ready",
        defaultValue: "Ready for a notification tap"
    )

    public init() {
        _store = State(initialValue: Self.makeStore(connectionState: .disconnected))
        _coordinator = State(
            initialValue: MobilePushCoordinator(
                registration: PushTabNavigationPreviewRegistration()
            )
        )
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text(L10n.string(
                "mobile.push.preview.title",
                defaultValue: "Notification tab navigation"
            ))
            .font(.title2.weight(.semibold))
            .accessibilityIdentifier("PushTabNavigationTitle")

            Text(actionDescription)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("PushTabNavigationState")

            Text(statusDescription)
                .font(.footnote.monospaced())
                .accessibilityIdentifier("PushTabNavigationSelection")

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
                    surfaceId: "terminal-notes"
                )
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("PushTabTapButton")

            Button(L10n.string(
                "mobile.push.preview.reconnect",
                defaultValue: "Reconnect Mac"
            )) {
                let connectedStore = Self.makeStore(connectionState: .connected)
                store = connectedStore
                coordinator.bind(store: connectedStore)
                coordinator.workspacesDidChange()
                actionDescription = L10n.string(
                    "mobile.push.preview.connected",
                    defaultValue: "Mac connection active"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("PushReconnectButton")

            Button(L10n.string(
                "mobile.push.preview.tapMissing",
                defaultValue: "Tap notification for closed tab"
            )) {
                actionDescription = L10n.string(
                    "mobile.push.preview.missing",
                    defaultValue: "The notification targets a closed tab"
                )
                coordinator.handleTap(
                    workspaceId: "workspace-docs",
                    surfaceId: "terminal-closed"
                )
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("PushMissingTabButton")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            coordinator.bind(store: store)
        }
        .alert(item: alertBinding) { _ in
            Alert(
                title: Text(L10n.string(
                    "mobile.push.tabUnavailable.title",
                    defaultValue: "Tab unavailable"
                )),
                message: Text(L10n.string(
                    "mobile.push.tabUnavailable.message",
                    defaultValue: "This tab is no longer available on your Mac."
                )),
                dismissButton: .default(Text(L10n.string(
                    "mobile.common.ok",
                    defaultValue: "OK"
                ))) {
                    coordinator.dismissTabUnavailableAlert()
                }
            )
        }
    }

    private var statusDescription: String {
        let workspace = store.selectedWorkspaceID?.rawValue ?? "none"
        let terminal = store.selectedTerminalID?.rawValue ?? "none"
        return "workspace=\(workspace)\nterminal=\(terminal)"
    }

    private var alertBinding: Binding<MobilePushCoordinator.TabUnavailableAlert?> {
        Binding(
            get: { coordinator.tabUnavailableAlert },
            set: { value in
                if value == nil {
                    coordinator.dismissTabUnavailableAlert()
                }
            }
        )
    }

    private static func makeStore(
        connectionState: MobileConnectionState
    ) -> CMUXMobileShellStore {
        CMUXMobileShellStore(
            isSignedIn: true,
            connectionState: connectionState,
            workspaces: connectionState == .connected ? [
                MobileWorkspacePreview(
                    id: "workspace-docs",
                    name: "Docs",
                    terminals: [
                        MobileTerminalPreview(id: "terminal-notes", name: "Notes")
                    ]
                )
            ] : []
        )
    }
}
#endif

import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Hosts ``WorkspaceShellView`` for every authenticated state that renders the
/// workspace shell: the startup stored-Mac reconnect window, the connected
/// shell, and the offline shell after a failed reconnect. The restoring window
/// only varies the inputs passed down; this host and the shell's navigation
/// paths stay mounted across restoring → connected → offline transitions.
/// Root-owned presentation actions preserve an open Settings sheet across the
/// same transitions. Mounting a different view per connection state destroyed
/// that state and dismissed Settings when reconnection finished.
struct WorkspaceShellHost: View {
    private static let loadingTimeout: Duration = .seconds(10)

    @Bindable var store: CMUXMobileShellStore
    /// True while the startup stored-Mac reconnect window is active. Drives the
    /// shell's initial-loading and timed-out inputs; never this host's identity.
    let isRestoringStoredMac: Bool
    let signOut: @MainActor @Sendable () -> Void
    /// This host persists behind Settings and across reconnect transitions, so
    /// it owns observation of the method that gates its pairing affordances.
    let connectionMethodStore: MobileConnectionMethodStore?
    let showAddDevice: () -> Void
    let showPairingScanner: () -> Void
    var showSettings: () -> Void = {}
    var deviceTreePresentation = MobileChildSheetPresentation()
    var taskComposerPresentation = MobileChildSheetPresentation()
    let reconnectStoredMac: () -> Void
    let workspaceListDidBecomeVisible: @MainActor @Sendable () async -> Void

    @Environment(AuthCoordinator.self) private var authManager
    @State private var loadingTimedOut = false
    @State private var retryGeneration = 0
    @State private var observedConnectionMethod: MobileConnectionMethod?

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: signOut,
            isInitialConnectionLoading: isRestoringStoredMac && !loadingTimedOut,
            initialConnectionTimedOut: isRestoringStoredMac && loadingTimedOut,
            retryInitialConnection: retry,
            showAddDevice: allowsManualPairing ? showAddDevice : nil,
            showPairingScanner: allowsManualPairing ? showPairingScanner : nil,
            showSettings: showSettings,
            deviceTreePresentation: deviceTreePresentation,
            taskComposerPresentation: taskComposerPresentation
        )
        .task(id: deadlineTaskID) {
            await updateLoadingDeadline()
        }
        .task {
            await workspaceListDidBecomeVisible()
        }
        .task(id: connectionMethodStore.map(ObjectIdentifier.init)) {
            guard let connectionMethodStore else {
                observedConnectionMethod = nil
                return
            }
            for await method in connectionMethodStore.changes() {
                observedConnectionMethod = method
            }
        }
    }

    private var allowsManualPairing: Bool {
        #if os(iOS)
        (observedConnectionMethod ?? connectionMethodStore?.method) == .tailscale
        #else
        true
        #endif
    }

    private struct DeadlineTaskID: Equatable {
        let isRestoringStoredMac: Bool
        let retryGeneration: Int
    }

    /// Restarts the deadline whenever the restoring window opens/closes or the
    /// user retries, so a stale timeout can never outlive its attempt.
    private var deadlineTaskID: DeadlineTaskID {
        DeadlineTaskID(
            isRestoringStoredMac: isRestoringStoredMac,
            retryGeneration: retryGeneration
        )
    }

    private func updateLoadingDeadline() async {
        loadingTimedOut = false
        guard isRestoringStoredMac else { return }
        do {
            try await ContinuousClock().sleep(for: Self.loadingTimeout)
        } catch {
            return
        }
        guard store.connectionState != .connected else { return }
        loadingTimedOut = true
    }

    private func retry() {
        loadingTimedOut = false
        retryGeneration &+= 1
        store.resumeForegroundRefresh()
        Task {
            await authManager.revalidateSession()
            reconnectStoredMac()
        }
    }
}

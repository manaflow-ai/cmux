import CmuxAuthRuntime
import CmuxMobileShell
import SwiftUI

/// Hosts ``WorkspaceShellView`` for every authenticated state that renders the
/// workspace shell: the startup stored-Mac reconnect window, the connected
/// shell, and the offline shell after a failed reconnect. The restoring window
/// only varies the inputs passed down; this host (and therefore the shell's
/// presentation state — an open Settings sheet, navigation paths) stays
/// mounted across restoring → connected → offline transitions. Mounting a
/// different view per connection state destroyed that state: a Settings sheet
/// opened during the reconnect window dismissed itself the moment the
/// reconnection finished.
struct WorkspaceShellHost: View {
    private static let loadingTimeout: Duration = .seconds(10)

    @Bindable var store: CMUXMobileShellStore
    /// True while the startup stored-Mac reconnect window is active. Drives the
    /// shell's initial-loading and timed-out inputs; never this host's identity.
    let isRestoringStoredMac: Bool
    let signOut: @MainActor @Sendable () -> Void
    let showAddDevice: (() -> Void)?
    let showPairingScanner: (() -> Void)?
    let reconnectStoredMac: () -> Void

    @Environment(AuthCoordinator.self) private var authManager
    @State private var loadingTimedOut = false
    @State private var retryGeneration = 0

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: signOut,
            isInitialConnectionLoading: isRestoringStoredMac && !loadingTimedOut,
            initialConnectionTimedOut: isRestoringStoredMac && loadingTimedOut,
            retryInitialConnection: retry,
            showAddDevice: showAddDevice,
            showPairingScanner: showPairingScanner
        )
        .task(id: deadlineTaskID) {
            await updateLoadingDeadline()
        }
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

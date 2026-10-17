import CmuxAuthRuntime
import CmuxMobileShell
import SwiftUI

/// Hosts the chat-first shell for every authenticated state with a saved Mac.
/// The startup stored-Mac reconnect window, connected shell, and offline shell
/// stay mounted through one view identity so the chat navigation survives a
/// reconnect transition.
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
    let showAddDevice: (() -> Void)?
    let showPairingScanner: (() -> Void)?
    var tailscalePairingRequired = false
    var showSettings: () -> Void = {}
    var showComputers: () -> Void = {}
    /// Present the SSH computer form (PRD D6). `nil` hides SSH add actions.
    var showAddSSHComputer: (() -> Void)? = nil
    var taskComposerPresentation = MobileChildSheetPresentation()
    let reconnectStoredMac: () -> Void
    let workspaceListDidBecomeVisible: @MainActor @Sendable () async -> Void

    @Environment(AuthCoordinator.self) private var authManager
    @State private var loadingTimedOut = false
    @State private var retryGeneration = 0

    var body: some View {
        MobileChatHomeView(
            store: store,
            isRestoringStoredMac: isRestoringStoredMac && !loadingTimedOut,
            showAddDevice: showAddDevice,
            showSettings: showSettings,
            showComputers: showComputers
        )
        .task(id: deadlineTaskID) {
            await updateLoadingDeadline()
        }
        .task {
            await workspaceListDidBecomeVisible()
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

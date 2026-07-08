import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import SwiftUI

struct RestoringStoredMacWorkspaceShell: View {
    private static let loadingTimeout: Duration = .seconds(10)

    @Bindable var store: CMUXMobileShellStore
    let signOut: () -> Void
    let showAddDevice: (() -> Void)?
    let telemetryConsentStore: MobileTelemetryConsentStore
    let reconnectStoredMac: () -> Void

    @Environment(AuthCoordinator.self) private var authManager
    @State private var loadingTimedOut = false
    @State private var retryGeneration = 0

    var body: some View {
        WorkspaceShellView(
            store: store,
            signOut: signOut,
            isInitialConnectionLoading: !loadingTimedOut,
            initialConnectionTimedOut: loadingTimedOut,
            retryInitialConnection: retry,
            showAddDevice: showAddDevice,
            telemetryConsentStore: telemetryConsentStore
        )
        .task(id: deadlineTaskID) {
            await updateLoadingDeadline()
        }
    }

    private var deadlineTaskID: Int {
        (retryGeneration &* 2) + 1
    }

    private func updateLoadingDeadline() async {
        loadingTimedOut = false
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

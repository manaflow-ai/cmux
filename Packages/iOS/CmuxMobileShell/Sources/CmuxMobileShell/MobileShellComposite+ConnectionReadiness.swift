import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    var connectionEstablishmentIsAllowed: Bool {
        foregroundRefreshIsActive && runtime?.connectionReadiness?.permitsConnection != false
    }

    func startObservingConnectionReadiness() {
        guard connectionReadinessTask == nil, let readiness = runtime?.connectionReadiness else { return }
        let changes = readiness.changes()
        connectionReadinessTask = Task { [weak self] in
            for await ready in changes {
                guard let self, !Task.isCancelled else { return }
                if ready {
                    self.recoverPendingInactiveRecoveryIfNeeded()
                } else {
                    self.pendingInactiveRecoveryTrigger = .foreground
                    self.storedMacReconnectDeadlineTask?.cancel()
                }
            }
        }
    }
}

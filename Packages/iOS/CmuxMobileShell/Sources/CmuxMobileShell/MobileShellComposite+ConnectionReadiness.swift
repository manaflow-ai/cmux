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
                self.connectionReadinessDidChange(ready)
            }
        }
    }

    func connectionReadinessDidChange(_ ready: Bool) {
        if ready {
            recoverPendingInactiveRecoveryIfNeeded()
        } else {
            if pendingInactiveRecoveryTrigger == nil { pendingInactiveRecoveryTrigger = .foreground }
            storedMacReconnectDeadlineTask?.cancel()
        }
    }

}

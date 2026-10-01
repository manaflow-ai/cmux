import Foundation

extension CmuxTuiSurfaceProvider {
    fileprivate func resetRecoveryRetry() {
        recoveryRetryTask?.cancel(); recoveryRetryTask = nil; recoveryRetryCount = 0
    }
    fileprivate func scheduleRecoveryRetry() {
        guard recoveryRetryTask == nil else { return }
        let delay = Self.recoveryRetryDelays[min(recoveryRetryCount, Self.recoveryRetryDelays.count - 1)]
        recoveryRetryCount = min(recoveryRetryCount + 1, Self.recoveryRetryDelays.count - 1)
        let lifecycle = lifecycleGeneration
        recoveryRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.recoveryRetryTask = nil
            guard self.lifecycleGeneration == lifecycle, self.isRegisteredInCatalog() else { return }
            await self.refreshCurrentGraph(force: true)
        }
    }
}

import CmuxCloud
import CmuxCloudMachines
import Foundation

/// Refresh ownership stays on the panel; only immutable requests survive suspension.
extension MachinesPanelViewModel {
    func refreshStats() {
        statsTask?.cancel()
        statsTask = nil
        statsID = nil
        guard isCloudEnabled(), let client = client ?? VMClient.shared else { return }
        let ids = machines.filter { $0.capabilities.stats }.map(\.id)
        guard !ids.isEmpty else { return }
        let requestID = UUID()
        statsID = requestID
        statsTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { _ = try? await client.stats(id: id) } }
            }
            guard let self, self.statsID == requestID else { return }
            self.statsTask = nil
            self.statsID = nil
        }
    }

    /// Samples machines advertising stats support. Sleeping machines report
    /// `asleep` without being woken, so polling never costs the user anything.
    /// Older servers omitting the flag retain the desktop-only polling policy
    /// through capability decoding; explicit support overrides that fallback.
    func refreshUsage() {
        guard isCloudEnabled(), usageTask == nil else { return }
        if let retryNotBefore = usageRetryNotBefore, retryNotBefore > Date() { return }
        guard let client = MachineUsageClient.shared else { return }
        let generation = refreshGeneration
        usageTask = Task { [weak self] in
            defer { if generation == self?.refreshGeneration { self?.usageTask = nil } }
            do {
                let usage = (try await client.teamUsage()).byMachineID
                guard !Task.isCancelled, let self, self.isCloudEnabled() else { return }
                self.usageFailureCount = 0; self.usageRetryNotBefore = nil
                self.applyUsage(usage)
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, let self else { return }
                self.usageFailureCount = min(self.usageFailureCount + 1, 4)
                self.usageRetryNotBefore = Date().addingTimeInterval(Self.usageBackoffDelay(failureCount: self.usageFailureCount))
            }
        }
    }

    func startPolling() {
        wantsPolling = true
        guard isCloudEnabled() else { pausePolling(); return }
        // Showing the panel or returning online is a recovery; polls are not.
        recoverList()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, pollingClock] in
            while !Task.isCancelled {
                do { try await pollingClock.sleep(for: Self.pollInterval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func stopPolling() { wantsPolling = false; pausePolling() }

}

import CmuxCloudMachines
import Foundation

/// Refresh ownership stays on the panel; only immutable requests survive suspension.
extension MachinesPanelViewModel {
    func refreshStats() {
        guard isCloudEnabled(), statsTask == nil, let client = client ?? VMClient.shared else { return }
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

    func startPolling() {
        wantsPolling = true
        guard isCloudEnabled() else { pausePolling(); return }
        refresh()
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

import CmuxAuthRuntime
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

    /// Starts a list read at the owner boundary. Automatic reads present a
    /// transient failure as reconnecting; routine polls keep a settled outage
    /// actionable until that poll itself fails or succeeds.
    func refresh(routinePoll: Bool = false) {
        guard isCloudEnabled(), let client = client ?? VMClient.shared else { return }
        guard refreshTask == nil else {
            refreshRequestedWhileLoading = true
            if !routinePoll {
                updateListRefreshPresentation(isRecovering: true)
                refreshRequestedWhileLoadingIsRecovery = true
            }
            return
        }
        updateListRefreshPresentation(isLoading: true, isRecovering: !routinePoll)
        let generation = refreshGeneration
        let scope = machinePinStore?.scopeIdentifier
        // The New Machine sheet's cache reuses this read for its plan and count.
        let sheetCacheScope = NewMachineSheetDataCache.shared?.scopeForIngest
        refreshTask = Task { [weak self] in
            // Only the last read in flight ends loading; a retired or chained one must not.
            defer { self?.clearListLoadingIfIdle() }
            let result: Result<VMListPage, Error>
            do { result = .success(try await client.listPage()) }
            catch { result = .failure(error) }
            if case .success(let page) = result {
                NewMachineSheetDataCache.shared?.ingest(page: page, scope: sheetCacheScope)
            }
            guard !Task.isCancelled, let self, generation == self.refreshGeneration else { return }
            self.applyRefreshResult(result, generation: generation, scope: scope)
            self.refreshTask = nil
            if self.refreshRequestedWhileLoading {
                let isRecovery = self.refreshRequestedWhileLoadingIsRecovery
                self.refreshRequestedWhileLoading = false
                self.refreshRequestedWhileLoadingIsRecovery = false
                self.refresh(routinePoll: !isRecovery)
            } else {
                self.updateListRefreshPresentation(isRecovering: false)
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
                self.refresh(routinePoll: true)
            }
        }
    }

    func stopPolling() { wantsPolling = false; pausePolling() }

    /// A wake is a return: a read that spanned the sleep, or the poll that fires
    /// on wake, can fail before the service answers again. Only a list that is
    /// polling recovers; a hidden panel recovers when it is shown. Offline, the
    /// coordinator refuses the read and the list keeps waiting for the network.
    func systemDidWake() {
        guard pollTask != nil else { return }
        recoverList()
    }

    /// Reuses wake recovery when a visible panel returns to the foreground.
    func applicationDidBecomeActive() { guard pollTask != nil else { return }; recoverList() }

}

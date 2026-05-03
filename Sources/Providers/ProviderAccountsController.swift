import AppKit
import Foundation

// MARK: - Controller

@MainActor
final class ProviderAccountsController: ObservableObject {
    static let shared = ProviderAccountsController()

    @Published private(set) var snapshots: [UUID: ProviderUsageSnapshot] = [:]
    @Published private(set) var fetchErrors: [UUID: String] = [:]
    /// Keyed by providerId
    @Published private(set) var incidents: [String: [ProviderIncident]] = [:]
    /// Keyed by providerId
    @Published private(set) var statusLoaded: [String: Bool] = [:]
    /// Keyed by providerId
    @Published private(set) var statusFetchFailed: [String: Bool] = [:]
    /// Keyed by providerId
    @Published private(set) var statusHasSucceeded: [String: Bool] = [:]
    @Published private(set) var isRefreshing: Bool = false

    /// Hard cap on a single provider usage/status fetch before it is dropped
    /// with a timeout error. Prevents one hung backend from pushing the task
    /// group past the 60s tick cadence and dropping later scheduled refreshes.
    private static let perFetchTimeout: TimeInterval = 20

    private let queue = DispatchQueue(label: "com.cmuxterm.provider-accounts.timer")
    private var timer: DispatchSourceTimer?
    private var tickCount: Int = 0
    private var currentTask: Task<Void, Never>?
    private var taskGeneration: Int = 0
    private var occlusionObserver: NSObjectProtocol?
    private var wasVisible: Bool = false
    /// Flips to `true` during `stop()` so any timer / occlusion callback that
    /// was already queued when teardown ran is dropped before it can reopen a
    /// tick and fire extra provider requests.
    private var isStopped: Bool = true
    /// Flips to `true` when a timer/occlusion tick arrives while `currentTask`
    /// is still draining. Instead of dropping the signal we run one more tick
    /// as soon as the current one finishes, so a long fetch can't swallow the
    /// next scheduled refresh.
    private var hasPendingTick: Bool = false

    private init() {}

    // MARK: - Public API

    func start() {
        guard timer == nil else { return }
        isStopped = false

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 60.0)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                self.scheduleTick()
            }
        }
        timer = source
        source.resume()

        // Resume polling immediately when app transitions from hidden to visible.
        // Only fire on hidden→visible edges to avoid refresh churn when the
        // occlusion state toggles frequently (e.g. during window drags).
        wasVisible = NSApp.occlusionState.contains(.visible)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                let isVisible = NSApp.occlusionState.contains(.visible)
                if isVisible && !self.wasVisible {
                    self.scheduleTick(force: true)
                }
                self.wasVisible = isVisible
            }
        }
    }

    func stop() {
        isStopped = true
        timer?.cancel()
        timer = nil
        currentTask?.cancel()
        currentTask = nil
        hasPendingTick = false
        tickCount = 0
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
            occlusionObserver = nil
        }
        wasVisible = false
    }

    func refreshNow() {
        scheduleTick(force: true)
    }

    // MARK: - Private

    private func scheduleTick(force: Bool = false) {
        // `refreshNow()` routes through here too, so the stopped gate has to
        // live inside `scheduleTick` rather than only in the callback paths —
        // otherwise an explicit manual refresh could restart polling after
        // teardown.
        guard !isStopped else { return }
        if currentTask != nil && !force {
            // A refresh is already in flight. Record the signal and run one
            // more tick when the current task drains, instead of silently
            // dropping it and waiting another 60s.
            hasPendingTick = true
            return
        }
        // A forced refresh replaces any in-flight task, so an earlier queued
        // signal is already subsumed by the new run — clearing the flag stops
        // the completion handler from scheduling a redundant second pass.
        hasPendingTick = false
        currentTask?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tick(generation: generation, force: force)
            if self.taskGeneration == generation {
                self.currentTask = nil
                if self.hasPendingTick && !self.isStopped {
                    self.hasPendingTick = false
                    self.scheduleTick()
                }
            }
        }
    }

    private func tick(generation: Int, force: Bool = false) async {
        // Skip if app is occluded (not visible), unless forced
        if !force {
            if !NSApp.occlusionState.contains(.visible) {
                return
            }
        }

        // Bail out if a newer task has already replaced us
        guard taskGeneration == generation else { return }

        isRefreshing = true
        defer {
            // Only clear isRefreshing if no newer task has replaced us
            if taskGeneration == generation || currentTask == nil {
                isRefreshing = false
            }
        }

        let accounts = ProviderAccountStore.shared.accounts

        // Skip all network requests when no accounts are configured
        guard !accounts.isEmpty else {
            snapshots.removeAll()
            fetchErrors.removeAll()
            incidents.removeAll()
            statusLoaded.removeAll()
            statusFetchFailed.removeAll()
            statusHasSucceeded.removeAll()
            return
        }

        // Usage fetches run in parallel so one slow provider can't starve the
        // others. Results are applied back on the MainActor after the group
        // completes.
        let fetchResults = await withTaskGroup(of: (ProviderAccount, Result<ProviderUsageWindows, Error>?).self) { group -> [(ProviderAccount, Result<ProviderUsageWindows, Error>?)] in
            for account in accounts {
                guard let provider = ProviderRegistry.provider(id: account.providerId) else {
                    group.addTask { (account, nil) }
                    continue
                }
                group.addTask {
                    do {
                        let secret = try await ProviderAccountStore.shared.secret(for: account.id)
                        let result = try await ProviderAccountsController.withTimeout(seconds: Self.perFetchTimeout) {
                            try await provider.fetchUsage(secret)
                        }
                        return (account, .success(result))
                    } catch {
                        return (account, .failure(error))
                    }
                }
            }
            var out: [(ProviderAccount, Result<ProviderUsageWindows, Error>?)] = []
            for await item in group {
                out.append(item)
            }
            return out
        }

        guard !Task.isCancelled, taskGeneration == generation else { return }

        // Re-read the store after the await: the user may have removed
        // accounts or providers while fetches were in flight, and those
        // results must not be written back into the published state.
        let liveAccountIds = Set(ProviderAccountStore.shared.accounts.map(\.id))
        let liveProviderIds = Set(ProviderAccountStore.shared.accounts.map(\.providerId))

        for (account, outcome) in fetchResults {
            guard liveAccountIds.contains(account.id) else { continue }
            switch outcome {
            case nil:
                fetchErrors[account.id] = String(
                    localized: "providers.accounts.error.unknownProvider",
                    defaultValue: "Unknown provider: \(account.providerId)"
                )
            case .success(let result):
                snapshots[account.id] = ProviderUsageSnapshot(
                    accountId: account.id,
                    providerId: account.providerId,
                    displayName: account.displayName,
                    session: result.session,
                    week: result.week,
                    fetchedAt: Date()
                )
                fetchErrors.removeValue(forKey: account.id)
            case .failure(_ as CancellationError):
                continue
            case .failure(let error):
                fetchErrors[account.id] = Self.localizedFetchErrorMessage(error)
            }
        }

        // Clean up snapshots/errors for removed accounts.
        // Collect stale keys first — mutating a Dictionary while iterating its
        // Keys view is undefined behavior.
        let staleSnapshotIds = snapshots.keys.filter { !liveAccountIds.contains($0) }
        for id in staleSnapshotIds {
            snapshots.removeValue(forKey: id)
        }
        let staleErrorIds = fetchErrors.keys.filter { !liveAccountIds.contains($0) }
        for id in staleErrorIds {
            fetchErrors.removeValue(forKey: id)
        }

        // Clean up provider-keyed status state for providers with no remaining accounts
        let staleIncidentProviderIds = incidents.keys.filter { !liveProviderIds.contains($0) }
        for providerId in staleIncidentProviderIds {
            incidents.removeValue(forKey: providerId)
        }
        let staleLoadedProviderIds = statusLoaded.keys.filter { !liveProviderIds.contains($0) }
        for providerId in staleLoadedProviderIds {
            statusLoaded.removeValue(forKey: providerId)
        }
        let staleFailedProviderIds = statusFetchFailed.keys.filter { !liveProviderIds.contains($0) }
        for providerId in staleFailedProviderIds {
            statusFetchFailed.removeValue(forKey: providerId)
        }
        let staleSucceededProviderIds = statusHasSucceeded.keys.filter { !liveProviderIds.contains($0) }
        for providerId in staleSucceededProviderIds {
            statusHasSucceeded.removeValue(forKey: providerId)
        }

        // Fetch status incidents every 5th tick (every ~5 minutes)
        tickCount += 1
        if tickCount % 5 == 1 || force {
            let providerIds = liveProviderIds
            let statusResults = await withTaskGroup(of: (String, Result<[ProviderIncident], Error>?).self) { group -> [(String, Result<[ProviderIncident], Error>?)] in
                for providerId in providerIds {
                    guard let provider = ProviderRegistry.provider(id: providerId),
                          let fetchStatus = provider.fetchStatus else {
                        group.addTask { (providerId, nil) }
                        continue
                    }
                    group.addTask {
                        do {
                            let fetched = try await ProviderAccountsController.withTimeout(seconds: Self.perFetchTimeout) {
                                try await fetchStatus()
                            }
                            return (providerId, .success(fetched))
                        } catch {
                            return (providerId, .failure(error))
                        }
                    }
                }
                var out: [(String, Result<[ProviderIncident], Error>?)] = []
                for await item in group {
                    out.append(item)
                }
                return out
            }

            guard !Task.isCancelled, taskGeneration == generation else { return }

            // Re-check which providers still have an account so a provider
            // removed during the status fetch cannot reopen its status state.
            let currentProviderIds = Set(ProviderAccountStore.shared.accounts.map(\.providerId))

            for (providerId, outcome) in statusResults {
                guard currentProviderIds.contains(providerId) else { continue }
                switch outcome {
                case nil:
                    continue
                case .success(let fetched):
                    incidents[providerId] = fetched
                    statusLoaded[providerId] = true
                    statusFetchFailed[providerId] = false
                    statusHasSucceeded[providerId] = true
                case .failure:
                    // Keep previous incidents on failure; mark loaded so UI stops showing spinner
                    statusLoaded[providerId] = true
                    statusFetchFailed[providerId] = true
                }
            }
        }
    }

    // MARK: - Error mapping

    /// Ensures every string exposed through `fetchErrors` is routed through
    /// the app's `.xcstrings` catalog. Only app-owned errors are trusted to
    /// return UI-ready localized `errorDescription`; everything else is
    /// replaced with a generic catalog string so raw OS/framework wording
    /// never leaks into the UI.
    private static func localizedFetchErrorMessage(_ error: Error) -> String {
        if let storeError = error as? ProviderAccountStoreError,
           let description = storeError.errorDescription {
            return description
        }
        if let claudeError = error as? ClaudeUsageFetchError,
           let description = claudeError.errorDescription {
            return description
        }
        if let codexError = error as? CodexUsageFetchError,
           let description = codexError.errorDescription {
            return description
        }
        if let timeoutError = error as? ProviderFetchTimeoutError,
           let description = timeoutError.errorDescription {
            return description
        }
        NSLog("ProviderAccountsController: fetch error: \(error)")
        return String(
            localized: "providers.accounts.error.fetchFailedGeneric",
            defaultValue: "Could not refresh usage. Please try again."
        )
    }

    // MARK: - Timeout helper

    struct ProviderFetchTimeoutError: Error, LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? {
            String(
                localized: "providers.accounts.error.timeout",
                defaultValue: "Provider fetch timed out after \(Int(seconds))s."
            )
        }
    }

    /// Runs `operation` under a deadline; a timely exit requires `operation`
    /// to honor cancellation (URLSession does via `URLError.cancelled`).
    nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProviderFetchTimeoutError(seconds: seconds)
            }
            guard let value = try await group.next() else {
                throw ProviderFetchTimeoutError(seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    }
}

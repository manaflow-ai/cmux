import Foundation

@MainActor
protocol BrowserHiddenWebViewDiscardManagerDelegate: AnyObject {
    var hiddenWebViewDiscardSnapshot: BrowserHiddenWebViewDiscardManager.BlockerSnapshot { get }
    var hiddenWebViewDiscardHiddenAt: Date? { get }
    var hiddenWebViewDiscardWebViewInstanceID: UUID { get }

    func hiddenWebViewDiscardManagerDidRequestDiscard(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
    func hiddenWebViewDiscardManagerPolicyDidChange(
        _ manager: BrowserHiddenWebViewDiscardManager,
        reason: String
    )
}

@MainActor
final class BrowserHiddenWebViewDiscardManager {
    struct BlockerSnapshot {
        let isClosing: Bool
        let isVisibleInUI: Bool
        let shouldRenderWebView: Bool
        let hasPendingRemoteNavigation: Bool
        let hasCurrentURL: Bool
        let isLoading: Bool
        let webViewIsLoading: Bool
        let isDownloading: Bool
        let activeDownloadCount: Int
        let preferredDeveloperToolsVisible: Bool
        let isDeveloperToolsVisible: Bool
        let isElementFullscreenActive: Bool
        let isReactGrabActive: Bool
        let hasPopups: Bool
    }

    weak var delegate: BrowserHiddenWebViewDiscardManagerDelegate?

    private var discardTimer: DispatchSourceTimer?
    private var policyObserver: NSObjectProtocol?
    private var policyState = BrowserHiddenWebViewDiscardPolicy.resolved()
    private var scheduleGeneration: UInt64 = 0

    private(set) var isDiscardedForMemory: Bool = false
    private(set) var discardedAt: Date?
    private(set) var lastDiscardReason: String?
    private(set) var lastRestoreReason: String?
    private(set) var restoredSessionShouldRenderWebView: Bool?

    var hasScheduledDiscard: Bool {
        discardTimer != nil
    }

    static func enforceLiveHiddenLimitForTesting(reason: String = "test.lru_cap") {
        BrowserHiddenWebViewDiscardRegistry.shared.enforceLimitForTesting(reason: reason)
    }

    func blockers(for snapshot: BlockerSnapshot) -> [String] {
        var blockers: [String] = []
        if !BrowserHiddenWebViewDiscardPolicy.isEnabled { blockers.append("policy_disabled") }
        if snapshot.isClosing { blockers.append("closing") }
        if isDiscardedForMemory { blockers.append("already_discarded") }
        if snapshot.isVisibleInUI { blockers.append("visible") }
        if !snapshot.shouldRenderWebView { blockers.append("not_rendered") }
        if snapshot.hasPendingRemoteNavigation { blockers.append("pending_remote_navigation") }
        if !snapshot.hasCurrentURL { blockers.append("no_url") }
        if snapshot.isLoading || snapshot.webViewIsLoading { blockers.append("loading") }
        if snapshot.isDownloading || snapshot.activeDownloadCount != 0 { blockers.append("download") }
        if snapshot.preferredDeveloperToolsVisible || snapshot.isDeveloperToolsVisible {
            blockers.append("developer_tools")
        }
        if snapshot.isElementFullscreenActive { blockers.append("fullscreen") }
        if snapshot.isReactGrabActive { blockers.append("react_grab") }
        if snapshot.hasPopups { blockers.append("popup") }
        return blockers
    }

    func scheduleIfNeeded(reason: String) {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil

        guard let delegate else {
            BrowserHiddenWebViewDiscardRegistry.shared.noteInactive(self)
            return
        }
        guard blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else {
            BrowserHiddenWebViewDiscardRegistry.shared.noteInactive(self)
            return
        }

        let observedWebViewInstanceID = delegate.hiddenWebViewDiscardWebViewInstanceID
        let generation = scheduleGeneration
        let hiddenAt = delegate.hiddenWebViewDiscardHiddenAt ?? Date()
        let elapsed = Date().timeIntervalSince(hiddenAt)
        let remaining = max(0, BrowserHiddenWebViewDiscardPolicy.hiddenDelay - elapsed)
        if remaining <= 0 {
            delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
            return
        }

        BrowserHiddenWebViewDiscardRegistry.shared.noteEligibleHidden(self)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.scheduleGeneration == generation else { return }
                guard let delegate = self.delegate else { return }
                guard delegate.hiddenWebViewDiscardWebViewInstanceID == observedWebViewInstanceID else { return }
                self.discardTimer?.cancel()
                self.discardTimer = nil
                delegate.hiddenWebViewDiscardManagerDidRequestDiscard(self, reason: reason)
            }
        }
        discardTimer = timer
        timer.resume()
    }

    func cancel() {
        scheduleGeneration &+= 1
        discardTimer?.cancel()
        discardTimer = nil
        BrowserHiddenWebViewDiscardRegistry.shared.noteInactive(self)
    }

    func installPolicyObserver() {
        policyState = BrowserHiddenWebViewDiscardPolicy.resolved()
        guard policyObserver == nil else { return }
        policyObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePolicyDefaultsChanged()
            }
        }
    }

    nonisolated func stop() {
        Task { @MainActor [self] in
            stopOnMainActor()
        }
    }

    func markDiscarded(reason: String, now: Date) {
        BrowserHiddenWebViewDiscardRegistry.shared.noteInactive(self)
        isDiscardedForMemory = true
        discardedAt = now
        lastDiscardReason = reason
        updateRestoredSessionRenderIntent(true)
    }

    @discardableResult
    func restoreIfNeeded(reason: String, performRestore: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performRestore()
        return true
    }

    @discardableResult
    func reactivateWithoutNavigation(reason: String, performReactivate: () -> Void) -> Bool {
        guard isDiscardedForMemory else { return false }
        cancel()
        guard clearDiscardState(reason: reason) else { return false }
        updateRestoredSessionRenderIntent(nil)
        performReactivate()
        return true
    }

    func updateRestoredSessionRenderIntent(_ shouldRenderWebView: Bool?) {
        restoredSessionShouldRenderWebView = shouldRenderWebView
    }

    @discardableResult
    func clearDiscardState(reason: String) -> Bool {
        guard isDiscardedForMemory else { return false }
        isDiscardedForMemory = false
        discardedAt = nil
        lastRestoreReason = reason
        return true
    }

    func resetMetadata() {
        cancel()
        isDiscardedForMemory = false
        discardedAt = nil
        lastDiscardReason = nil
        lastRestoreReason = nil
        updateRestoredSessionRenderIntent(nil)
    }

    private func handlePolicyDefaultsChanged() {
        let nextPolicyState = BrowserHiddenWebViewDiscardPolicy.resolved()
        guard policyState != nextPolicyState else { return }
        policyState = nextPolicyState
        delegate?.hiddenWebViewDiscardManagerPolicyDidChange(self, reason: "policy_changed")
    }

    private func stopOnMainActor() {
        cancel()
        BrowserHiddenWebViewDiscardRegistry.shared.noteInactive(self)
        if let policyObserver {
            NotificationCenter.default.removeObserver(policyObserver)
            self.policyObserver = nil
        }
    }
}

@MainActor
private final class BrowserHiddenWebViewDiscardRegistry {
    static let shared = BrowserHiddenWebViewDiscardRegistry()

    private struct Entry {
        weak var manager: BrowserHiddenWebViewDiscardManager?
        var hiddenAt: Date
        var sequence: UInt64
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var sequence: UInt64 = 0
    private var enforcementScheduled = false

    func noteEligibleHidden(_ manager: BrowserHiddenWebViewDiscardManager) {
        guard BrowserHiddenWebViewDiscardPolicy.isEnabled else {
            noteInactive(manager)
            return
        }
        guard let delegate = manager.delegate else {
            noteInactive(manager)
            return
        }
        guard manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else {
            noteInactive(manager)
            return
        }

        sequence &+= 1
        entries[ObjectIdentifier(manager)] = Entry(
            manager: manager,
            hiddenAt: delegate.hiddenWebViewDiscardHiddenAt ?? Date(),
            sequence: sequence
        )
        scheduleLimitEnforcement()
    }

    func noteInactive(_ manager: BrowserHiddenWebViewDiscardManager) {
        entries.removeValue(forKey: ObjectIdentifier(manager))
    }

    func enforceLimitForTesting(reason: String = "test.lru_cap") {
        enforceLimit(reason: reason)
    }

    private func scheduleLimitEnforcement() {
        guard !enforcementScheduled else { return }
        enforcementScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.enforceLimit(reason: "lru_cap")
            }
        }
    }

    private func enforceLimit(reason: String) {
        enforcementScheduled = false
        pruneDeadEntries()

        guard BrowserHiddenWebViewDiscardPolicy.isEnabled else {
            entries.removeAll()
            return
        }

        let maxLiveHiddenCount = BrowserHiddenWebViewDiscardPolicy.maxLiveHiddenCount
        let candidates = liveEligibleEntries()
        guard candidates.count > maxLiveHiddenCount else { return }

        let oldestFirst = candidates.sorted { lhs, rhs in
            if lhs.entry.hiddenAt != rhs.entry.hiddenAt {
                return lhs.entry.hiddenAt < rhs.entry.hiddenAt
            }
            return lhs.entry.sequence < rhs.entry.sequence
        }
        let discardCount = candidates.count - maxLiveHiddenCount
        for candidate in oldestFirst.prefix(discardCount) {
            candidate.manager.delegate?.hiddenWebViewDiscardManagerDidRequestDiscard(
                candidate.manager,
                reason: reason
            )
        }
        pruneDeadEntries()
    }

    private func pruneDeadEntries() {
        entries = entries.filter { _, entry in
            entry.manager != nil
        }
    }

    private func liveEligibleEntries() -> [(manager: BrowserHiddenWebViewDiscardManager, entry: Entry)] {
        var nextEntries: [ObjectIdentifier: Entry] = [:]
        var result: [(manager: BrowserHiddenWebViewDiscardManager, entry: Entry)] = []
        for (id, entry) in entries {
            guard let manager = entry.manager else { continue }
            guard let delegate = manager.delegate,
                  manager.blockers(for: delegate.hiddenWebViewDiscardSnapshot).isEmpty else {
                continue
            }
            nextEntries[id] = entry
            result.append((manager, entry))
        }
        entries = nextEntries
        return result
    }
}

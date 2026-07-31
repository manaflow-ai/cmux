import Foundation
import Observation

/// Main-actor recording facade for the Vault history timeline.
///
/// Lifecycle hooks (workspace create/rename/close, window open/close) call
/// ``record(_:)``, which stamps nothing itself — callers build the full
/// ``VaultHistoryEvent`` — and forwards to the persistence actor off the
/// caller's critical path. `revision` bumps on every recorded event so the
/// History view knows to re-query without observing the store directly.
@MainActor
@Observable
final class VaultHistoryEventLog {
    static let shared = VaultHistoryEventLog(
        store: VaultHistoryEventStore(fileURL: defaultFileURL())
    )

    /// Monotonic count of recorded events this launch; observed by the
    /// History view to refresh after new activity. Bumped only after the
    /// event reached the store, so a refresh triggered by the bump always
    /// sees the event it announces.
    private(set) var revision: UInt64 = 0

    private let store: VaultHistoryEventStore
    /// Tail of the serialized append chain; each record awaits its
    /// predecessor so events persist in call order.
    private var pendingRecordTask: Task<Void, Never>?

    init(store: VaultHistoryEventStore) {
        self.store = store
    }

    /// Whether lifecycle hooks should skip recording right now (bulk
    /// programmatic churn like session restore, or app termination).
    static var isRecordingSuppressed: Bool {
        guard let appDelegate = AppDelegate.shared else { return false }
        return shouldSuppressRecording(
            isApplyingSessionRestore: appDelegate.isApplyingSessionRestore,
            isTerminatingApp: appDelegate.isTerminatingApp
        )
    }

    nonisolated static func shouldSuppressRecording(
        isApplyingSessionRestore: Bool,
        isTerminatingApp: Bool
    ) -> Bool {
        isApplyingSessionRestore || isTerminatingApp
    }

    func record(_ event: VaultHistoryEvent) {
        let store = store
        let previous = pendingRecordTask
        pendingRecordTask = Task(priority: .utility) { [weak self] in
            await previous?.value
            await store.append(event)
            guard let self else { return }
            self.revision &+= 1
            NotificationCenter.default.post(
                name: .vaultHistoryEventLogDidChange,
                object: self
            )
        }
    }

    /// Persisted events, newest first, bounded by the store's retention policy.
    func recentEvents(limit: Int = Int.max) async -> [VaultHistoryEvent] {
        await store.recentEvents(limit: limit)
    }

    nonisolated private static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return appSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("vault-history-\(safeBundleId).jsonl", isDirectory: false)
    }
}

extension Notification.Name {
    static let vaultHistoryEventLogDidChange = Notification.Name(
        "cmux.vaultHistoryEventLogDidChange"
    )
}

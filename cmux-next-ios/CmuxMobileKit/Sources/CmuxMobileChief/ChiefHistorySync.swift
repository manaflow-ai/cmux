import CmuxConversationCore
import Foundation

/// Keeps every Chief conversation of the signed-in account on this phone (CMUX-24): the Mac's
/// Chief and each Cloud Chief, its whole history read into the device's SQLite store
/// (``ConversationTranscriptCache/sync(_:pageSize:fetch:)``), so Chief reads with no network
/// and a reconnect only fetches what is new.
///
/// One sync per conversation runs at a time; a request while one runs (a reconnect) runs again
/// once it ends. A failed sync retries with backoff, then waits for the next request (the next
/// foreground, network change or backend swap). ``cancelAll()`` (sign-out) stops every sync, and
/// the cache itself refuses a write for an account that is no longer active.
@MainActor
public final class ChiefHistorySync {
    /// Retries after a failed sync before it waits for the next request.
    static let maxAttempts = 5

    let clock: any Clock<Duration>
    private var running: [String: Task<Void, Never>] = [:]
    private var again: [String: Request] = [:]
    /// The last sync's result per conversation (tests, diagnostics).
    public private(set) var reports: [String: ConversationHistorySyncReport] = [:]
    /// Every sync finished or given up, in order (tests).
    var onFinish: (@MainActor (String, ConversationHistorySyncReport?) -> Void)?

    struct Request {
        var cache: ConversationTranscriptCache
        var pageSize: Int
        var fetch: @Sendable (Int?, Int) async throws -> ConversationHistoryPage
        var finished: (@Sendable () -> Void)?
    }

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Whether `key` is syncing now.
    public func isSyncing(_ key: String) -> Bool { running[key] != nil }

    /// Syncs `key` into `cache` with `fetch` (a backend's `history`). `finished` runs once this
    /// request is done with, whatever the outcome (a history-only backend closes there).
    public func sync(_ key: String, cache: ConversationTranscriptCache, pageSize: Int,
                     fetch: @escaping @Sendable (Int?, Int) async throws -> ConversationHistoryPage,
                     finished: (@Sendable () -> Void)? = nil) {
        let request = Request(cache: cache, pageSize: pageSize, fetch: fetch, finished: finished)
        guard running[key] == nil else {
            // The newer request wins: its backend is the live one.
            again[key]?.finished?()
            again[key] = request
            return
        }
        start(key, request)
    }

    private func start(_ key: String, _ request: Request) {
        running[key] = Task { [weak self, clock] in
            var report: ConversationHistorySyncReport?
            var attempt = 0
            while !Task.isCancelled {
                do {
                    report = try await request.cache.sync(key, pageSize: request.pageSize, fetch: request.fetch)
                    break
                } catch is CancellationError {
                    break
                } catch {
                    attempt += 1
                    guard attempt < Self.maxAttempts else { break }
                    try? await clock.sleep(for: Self.backoff(attempt))
                }
            }
            request.finished?()
            guard let self, !Task.isCancelled else { return }
            self.running[key] = nil
            if let report { self.reports[key] = report }
            self.onFinish?(key, report)
            if let next = self.again.removeValue(forKey: key) { self.start(key, next) }
        }
    }

    /// Sign-out or another account: every sync stops and none runs again.
    public func cancelAll() {
        for task in running.values { task.cancel() }
        running = [:]
        for request in again.values { request.finished?() }
        again = [:]
        reports = [:]
    }

    nonisolated static func backoff(_ attempt: Int) -> Duration {
        .seconds(min(60, 1 << min(attempt, 6)))
    }
}

public import Foundation
import CmuxNextWakeups

/// Agent waits on the App's downloads list (`browser.page.download.wait`, `cmux browser <tab|page> download`):
/// which download a wait answers with, and when it ends. Each download is reported to one wait, and a wait takes
/// a download that started up to ``recentStart`` before it, so a click's download that started (or even ended)
/// before the agent asked is still the one it gets; with none, it waits for the next. The list calls
/// ``started(_:tab:)`` for each new download and ``keep(only:)`` when rows go.
@MainActor
public final class BrowserDownloadWaits {
    /// How a wait ended.
    public enum Answer {
        /// The download ended (finished, failed, cancelled or blocked).
        case ended(BrowserDownload)
        /// No listed download has the asked id.
        case unknownID
        /// Nothing ended in time.
        case timedOut
    }

    public static let recentStart: Duration = .seconds(60)

    private var starts: [ObjectIdentifier: (at: ContinuousClock.Instant, tab: String)] = [:]
    private var reported: Set<ObjectIdentifier> = []
    /// Waits for the next download from a tab (nil: any tab), oldest first, by token.
    private var next: [(token: Int, tab: String?, take: (BrowserDownload) -> Bool)] = []
    private var lastToken = 0
    private let clock: any Clock<Duration>

    public init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// A download from tab `key` started.
    public func started(_ item: BrowserDownload, tab key: String) {
        starts[ObjectIdentifier(item)] = (.now, key)
        // One wait per download: the oldest one still waiting for this tab's next (a wait whose deadline
        // already answered declines it, and the next one gets it).
        while let index = next.firstIndex(where: { $0.tab == nil || $0.tab == key }) {
            let waiter = next.remove(at: index)
            if waiter.take(item) {
                reported.insert(ObjectIdentifier(item))
                return
            }
        }
    }

    /// Forgets downloads no longer listed.
    public func keep(only listed: Set<ObjectIdentifier>) {
        starts = starts.filter { listed.contains($0.key) }
        reported.formIntersection(listed)
    }

    /// Waits up to `limit` for a download of `items` to end: the one with `id`, else tab `tab`'s (nil: any
    /// tab's) oldest unreported recent one, else the next one it starts.
    public func ended(id: String?, tab: String?, items: [BrowserDownload], within limit: Duration) async -> Answer {
        let began = ContinuousClock.now
        let remaining = { limit - (ContinuousClock.now - began) }
        let item: BrowserDownload
        var claimed = false
        if let id {
            guard let found = items.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else { return .unknownID }
            item = found
        } else if let recent = unreported(tab: tab, among: items) {
            item = recent
        } else {
            lastToken += 1
            let token = lastToken
            let newer = await within(limit, { take in self.next.append((token, tab, take)) })
            next.removeAll { $0.token == token }
            guard let newer else { return .timedOut }
            item = newer
            claimed = true  // `started` marked it reported for this wait
        }
        // Claimed while it runs, so a second wait does not take it too; a wait that times out gives it back,
        // so the agent's next wait follows the same download.
        let id = ObjectIdentifier(item)
        if !claimed { claimed = reported.insert(id).inserted }
        guard await within(remaining(), { done in item.onFinish { _ = done($0) } }) != nil else {
            // Only the wait that claimed it gives it back; another wait may still follow it.
            if claimed { reported.remove(id) }
            return .timedOut
        }
        return .ended(item)
    }

    private func unreported(tab key: String?, among items: [BrowserDownload]) -> BrowserDownload? {
        let since = ContinuousClock.now - Self.recentStart
        return items.first { item in
            let id = ObjectIdentifier(item)
            guard !reported.contains(id), let start = starts[id], start.at >= since else { return false }
            return key == nil || start.tab == key
        }
    }

    /// The download `start` hands its callback, or nil once `limit` passes or the call is cancelled.
    /// `start`'s callback answers whether this wait took the value (false once it already answered).
    private func within(_ limit: Duration, _ start: (@escaping (BrowserDownload) -> Bool) -> Void) async -> BrowserDownload? {
        let pending = Pending()
        let deadline = DemandTimer(owner: "browser.download.wait", clock: clock)
        deadline.schedule(after: limit) { @MainActor in _ = pending.finish(nil) }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.park(continuation)
                start { pending.finish($0) }
            }
        } onCancel: {
            Task { @MainActor in _ = pending.finish(nil) }
        }
    }

    /// One answer for one parked continuation; later answers do nothing.
    private final class Pending {
        private var continuation: CheckedContinuation<BrowserDownload?, Never>?
        private var answer: BrowserDownload??

        /// Parks `continuation`; resumes it at once when the answer came first (a cancel before the park).
        func park(_ continuation: CheckedContinuation<BrowserDownload?, Never>) {
            if let answer { return continuation.resume(returning: answer) }
            self.continuation = continuation
        }

        /// Answers once; false when an answer already came.
        @discardableResult
        func finish(_ value: BrowserDownload?) -> Bool {
            guard answer == nil else { return false }
            answer = .some(value)
            continuation?.resume(returning: value)
            continuation = nil
            return true
        }
    }
}

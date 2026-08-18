import Foundation

/// Keeps one reftable `HEAD` resolution per checkout, keyed by the reftable
/// stack signature, so the sidebar's repeated metadata refreshes consult `git`
/// only after the refs actually changed.
///
/// An unresolved read is kept too, or a repository `git` cannot answer for
/// would spawn a process on every refresh — but only briefly. A read fails for
/// transient reasons as well as permanent ones: the runner's wall-time bound,
/// a cancelled tracked-changes scan, a failed spawn. Those must not pin a
/// wrong answer until the next ref update, which for a quiet repository may
/// never come.
final class MemoizedGitReftableHeadReader: GitReftableHeadReading, @unchecked Sendable {
    private struct Entry {
        let stackSignature: String
        let head: GitReftableHead?
        /// When an unresolved read stops being reused. `nil` for a resolved
        /// one, which stays valid for as long as its signature does.
        let expiresAt: Date?
    }

    private let base: any GitReftableHeadReading
    private let unresolvedTimeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entriesByWorkTreeRoot: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(
        base: any GitReftableHeadReading,
        unresolvedTimeToLive: TimeInterval = 5,
        maximumEntryCount: Int = 64,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.base = base
        self.unresolvedTimeToLive = max(0, unresolvedTimeToLive)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.now = now
    }

    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        lock.lock()
        let cached = entriesByWorkTreeRoot[workTreeRoot]
        lock.unlock()
        if let cached, cached.stackSignature == stackSignature, isValid(cached) {
            return cached.head
        }

        let head = base.head(workTreeRoot: workTreeRoot, stackSignature: stackSignature)
        let entry = Entry(
            stackSignature: stackSignature,
            head: head,
            expiresAt: head == nil ? now().addingTimeInterval(unresolvedTimeToLive) : nil
        )

        lock.lock()
        if entriesByWorkTreeRoot.updateValue(entry, forKey: workTreeRoot) == nil {
            insertionOrder.append(workTreeRoot)
            while insertionOrder.count > maximumEntryCount {
                entriesByWorkTreeRoot.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        lock.unlock()
        return head
    }

    private func isValid(_ entry: Entry) -> Bool {
        guard let expiresAt = entry.expiresAt else { return true }
        return now() < expiresAt
    }
}

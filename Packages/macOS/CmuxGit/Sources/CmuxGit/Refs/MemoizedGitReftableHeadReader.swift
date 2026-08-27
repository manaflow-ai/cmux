import Foundation

/// Keeps one reftable `HEAD` resolution per checkout, keyed by the reftable
/// stack signature, so the sidebar's repeated metadata refreshes consult `git`
/// only after the refs actually changed.
///
/// Resolutions are single-flighted per checkout: a caller that arrives while
/// another is already resolving the same work tree waits for that result
/// instead of starting a second pair of `git` commands.
///
/// An unresolved read is kept too, or a repository `git` cannot answer for
/// would spawn a process on every refresh — but only briefly. A read fails for
/// transient reasons as well as permanent ones: the runner's wall-time bound, a
/// cancelled tracked-changes scan, a failed spawn. Those must not pin a wrong
/// answer until the next ref update, which for a quiet repository may never
/// come.
///
/// Synchronous by design. Callers already run on
/// ``GitMetadataService/blockingStatusQueue``, and the gitlink scan calls in
/// from inside a `WorkspaceChangesCancellationSignal` binding, which lives in
/// the thread dictionary — an actor hop would land on another thread and lose
/// it. So the coordination is an `NSCondition`, and waiting parks a thread that
/// is already in the blocking lane.
final class MemoizedGitReftableHeadReader: GitReftableHeadReading, @unchecked Sendable {
    private struct Entry {
        let stackSignature: String
        let head: GitReftableHead?
        /// When an unresolved read stops being reused. `nil` for a resolved
        /// one, which stays valid for as long as its signature does.
        let expiresAt: Date?
    }

    /// What a resolution is in flight *for*. The signature belongs in the key:
    /// two callers reading the stack either side of a ref update are asking
    /// different questions, and neither should clear the other's slot.
    private struct ResolutionKey: Hashable {
        let workTreeRoot: String
        let stackSignature: String
    }

    private let base: any GitReftableHeadReading
    private let unresolvedTimeToLive: TimeInterval
    private let maximumEntryCount: Int
    private let now: @Sendable () -> Date

    /// Guards every stored property below it, and wakes waiters when a
    /// resolution lands.
    private let condition = NSCondition()
    private var entriesByWorkTreeRoot: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private var resolutionsInFlight: Set<ResolutionKey> = []

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
        let key = ResolutionKey(workTreeRoot: workTreeRoot, stackSignature: stackSignature)
        condition.lock()
        while true {
            if let entry = entriesByWorkTreeRoot[workTreeRoot],
               entry.stackSignature == stackSignature,
               isValid(entry) {
                condition.unlock()
                return entry.head
            }
            guard resolutionsInFlight.contains(key) else { break }
            condition.wait()
        }
        resolutionsInFlight.insert(key)
        condition.unlock()

        let head = base.head(workTreeRoot: workTreeRoot, stackSignature: stackSignature)

        condition.lock()
        store(head, workTreeRoot: workTreeRoot, stackSignature: stackSignature)
        resolutionsInFlight.remove(key)
        condition.broadcast()
        condition.unlock()
        return head
    }

    private func store(
        _ head: GitReftableHead?,
        workTreeRoot: String,
        stackSignature: String
    ) {
        let entry = Entry(
            stackSignature: stackSignature,
            head: head,
            expiresAt: head == nil ? now().addingTimeInterval(unresolvedTimeToLive) : nil
        )
        guard entriesByWorkTreeRoot.updateValue(entry, forKey: workTreeRoot) == nil else {
            return
        }
        insertionOrder.append(workTreeRoot)
        while insertionOrder.count > maximumEntryCount {
            entriesByWorkTreeRoot.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    private func isValid(_ entry: Entry) -> Bool {
        guard let expiresAt = entry.expiresAt else { return true }
        return now() < expiresAt
    }
}

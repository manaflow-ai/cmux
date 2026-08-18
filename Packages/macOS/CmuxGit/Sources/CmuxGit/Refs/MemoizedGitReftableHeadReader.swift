import Foundation

/// Keeps one reftable `HEAD` resolution per checkout, keyed by the reftable
/// stack signature, so the sidebar's repeated metadata refreshes consult `git`
/// only after the refs actually changed.
///
/// Unresolved reads are remembered too: a repository `git` cannot answer for
/// must not spawn a process on every refresh either.
final class MemoizedGitReftableHeadReader: GitReftableHeadReading, @unchecked Sendable {
    private struct Entry {
        let stackSignature: String
        let head: GitReftableHead?
    }

    private let base: any GitReftableHeadReading
    private let maximumEntryCount: Int
    private let lock = NSLock()
    private var entriesByWorkTreeRoot: [String: Entry] = [:]
    private var insertionOrder: [String] = []

    init(base: any GitReftableHeadReading, maximumEntryCount: Int = 64) {
        self.base = base
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func head(workTreeRoot: String, stackSignature: String) -> GitReftableHead? {
        lock.lock()
        let cached = entriesByWorkTreeRoot[workTreeRoot]
        lock.unlock()
        if let cached, cached.stackSignature == stackSignature {
            return cached.head
        }

        let head = base.head(workTreeRoot: workTreeRoot, stackSignature: stackSignature)

        lock.lock()
        if entriesByWorkTreeRoot.updateValue(
            Entry(stackSignature: stackSignature, head: head),
            forKey: workTreeRoot
        ) == nil {
            insertionOrder.append(workTreeRoot)
            while insertionOrder.count > maximumEntryCount {
                entriesByWorkTreeRoot.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
        lock.unlock()
        return head
    }
}

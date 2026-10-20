/// A fixed-size FIFO set for identities whose duplicates arrive nearby.
///
/// Codex repeats response identities locally. Retaining a recent window keeps
/// those repeats deduplicated without making a long-lived transcript tailer
/// retain every response forever.
struct RecentIDSet<Element: Hashable & Sendable>: Sendable {
    private let capacity: Int
    private var members: Set<Element> = []
    private var insertionOrder: [Element] = []
    private var nextEvictionIndex = 0

    /// The number of identities currently retained.
    var count: Int { members.count }

    /// Creates an empty recent-identity set.
    ///
    /// - Parameter capacity: Maximum distinct identities to retain.
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        insertionOrder.reserveCapacity(capacity)
    }

    /// Inserts an identity, evicting the oldest distinct identity at capacity.
    ///
    /// - Parameter element: The identity to retain.
    /// - Returns: `true` when the identity was not already retained.
    mutating func insert(_ element: Element) -> Bool {
        guard !members.contains(element) else { return false }
        if insertionOrder.count < capacity {
            insertionOrder.append(element)
        } else {
            let evicted = insertionOrder[nextEvictionIndex]
            members.remove(evicted)
            insertionOrder[nextEvictionIndex] = element
            nextEvictionIndex = (nextEvictionIndex + 1) % capacity
        }
        members.insert(element)
        return true
    }
}

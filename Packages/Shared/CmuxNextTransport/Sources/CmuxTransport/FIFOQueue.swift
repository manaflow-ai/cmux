/// A FIFO queue with amortized constant-time dequeue and bounded compaction.
///
/// Transport actors use this instead of shifting an array on every dequeue: a slow peer can
/// create many queued events, and shifting the entire tail on every dequeue
/// turns that pressure into avoidable quadratic work.
public struct FIFOQueue<Element> {
    private var storage: [Element] = []
    private var head = 0

    /// Creates an empty queue.
    public init() {}

    /// Number of elements waiting to be dequeued.
    public var count: Int { storage.count - head }
    /// Whether the queue has no elements.
    public var isEmpty: Bool { head >= storage.count }
    /// The next element without removing it.
    public var first: Element? { isEmpty ? nil : storage[head] }

    /// Appends one element to the tail.
    public mutating func append(_ element: Element) {
        storage.append(element)
    }

    /// Appends all elements in source order.
    public mutating func append(contentsOf elements: [Element]) {
        storage.append(contentsOf: elements)
    }

    /// Removes and returns the oldest element, if any.
    public mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        let element = storage[head]
        head += 1
        compactIfNeeded()
        return element
    }

    /// Removes and returns the first element matching a predicate.
    public mutating func remove(
        where predicate: (Element) throws -> Bool
    ) rethrows -> Element? {
        guard !isEmpty,
            let index = try storage[head...].firstIndex(where: predicate)
        else { return nil }
        let element = storage.remove(at: index)
        compactIfNeeded()
        return element
    }

    /// Tests the queued elements without changing the queue.
    public func contains(where predicate: (Element) throws -> Bool) rethrows -> Bool {
        guard !isEmpty else { return false }
        return try storage[head...].contains(where: predicate)
    }

    /// Removes every queued element.
    public mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    private mutating func compactIfNeeded() {
        guard head > 32, head * 2 >= storage.count else { return }
        storage.removeSubrange(0..<head)
        head = 0
    }
}

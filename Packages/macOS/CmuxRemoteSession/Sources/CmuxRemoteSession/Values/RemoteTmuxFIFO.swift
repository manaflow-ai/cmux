/// A first-in, first-out queue whose front removals cost amortized O(1).
///
/// A control connection matches tmux's replies to its commands by position, so it keeps every
/// command it sent in order and takes one off the front per reply. An array pays a shift of
/// the whole remainder for each of those removals, which is O(n^2) for a queue n commands long,
/// and a catch-up queues several commands for every pane at once. Here the elements live in one
/// array behind a head index: removing from the front moves the index, and the dead prefix is
/// dropped once it is at least half of the storage, so each element is copied a constant number
/// of times however long the queue gets.
public struct RemoteTmuxFIFO<Element>: Sequence {
    /// The live elements are `storage[head...]`.
    var storage: [Element] = []
    var head = 0

    /// Creates an empty queue.
    public init() {}

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { head == storage.count }
    public var first: Element? { isEmpty ? nil : storage[head] }

    /// Adds `element` at the back.
    public mutating func append(_ element: Element) {
        storage.append(element)
    }

    /// Adds `elements` at the back, in order.
    public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        storage.append(contentsOf: elements)
    }

    /// Removes and returns the oldest element. The queue must not be empty.
    @discardableResult
    public mutating func removeFirst() -> Element {
        precondition(!isEmpty, "removeFirst() on an empty RemoteTmuxFIFO")
        let element = storage[head]
        head += 1
        compactIfMostlyDead()
        return element
    }

    /// Removes the `k` oldest elements. `k` must be between 0 and `count`.
    public mutating func removeFirst(_ k: Int) {
        precondition(k >= 0 && k <= count, "removeFirst(\(k)) on a RemoteTmuxFIFO of \(count)")
        head += k
        compactIfMostlyDead()
    }

    /// Removes the `k` newest elements, as when a batch that was just appended is withdrawn.
    public mutating func removeLast(_ k: Int) {
        precondition(k >= 0 && k <= count, "removeLast(\(k)) on a RemoteTmuxFIFO of \(count)")
        storage.removeLast(k)
        compactIfMostlyDead()
    }

    /// Removes every element.
    public mutating func removeAll() {
        storage.removeAll()
        head = 0
    }

    /// The oldest `maxLength` elements, or all of them if there are fewer.
    public func prefix(_ maxLength: Int) -> ArraySlice<Element> {
        storage[head..<(head + Swift.min(Swift.max(0, maxLength), count))]
    }

    /// Iterates the live elements, oldest first.
    public func makeIterator() -> ArraySlice<Element>.Iterator {
        storage[head...].makeIterator()
    }

    /// Drops the removed prefix once it is at least half of the storage. The copy moves at most
    /// as many elements as were removed since the last one, which is what keeps removal
    /// amortized O(1). Small queues skip it; their dead prefix is cheap to keep.
    private mutating func compactIfMostlyDead() {
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 32, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}

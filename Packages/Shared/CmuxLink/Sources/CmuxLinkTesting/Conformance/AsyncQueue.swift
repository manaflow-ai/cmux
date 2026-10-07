/// An unbounded FIFO with async `next()` (one consumer at a time).
public actor AsyncQueue<Element: Sendable> {
    private var items: [Element] = []
    private var waiter: CheckedContinuation<Element?, Never>?
    private var finished = false

    public init() {}

    public func push(_ item: Element) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: item)
        } else {
            items.append(item)
        }
    }

    public func finish() {
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    public var count: Int { items.count }

    public func next() async -> Element? {
        if !items.isEmpty { return items.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
}

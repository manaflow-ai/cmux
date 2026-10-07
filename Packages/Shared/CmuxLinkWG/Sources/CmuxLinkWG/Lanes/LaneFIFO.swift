/// A FIFO with amortized O(1) pops, for the transport's send queues.
struct LaneFIFO<Element> {
    private var storage: [Element] = []
    private var head = 0

    var isEmpty: Bool { head == storage.count }
    var count: Int { storage.count - head }

    mutating func push(_ element: Element) {
        storage.append(element)
    }

    mutating func pop() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        if head > 64, head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }
}

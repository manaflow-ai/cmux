struct BackendOnlyRendererFrameReleaseRingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var tail = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) -> Bool {
        guard count < storage.count else { return false }
        storage[tail] = element
        tail = (tail + 1) % storage.count
        count += 1
        return true
    }

    mutating func popFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }
}

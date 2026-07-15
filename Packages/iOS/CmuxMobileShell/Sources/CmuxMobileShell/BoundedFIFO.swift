struct BoundedFIFO<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    var first: Element? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    var last: Element? {
        guard count > 0 else { return nil }
        return storage[(head + count - 1) % storage.count]
    }

    mutating func append(_ element: Element) -> Bool {
        guard count < storage.count else { return false }
        let index = (head + count) % storage.count
        storage[index] = element
        count += 1
        return true
    }

    mutating func removeFirst() -> Element? {
        guard count > 0 else { return nil }
        let element = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return element
    }

    mutating func mutateFirst(_ body: (inout Element) -> Void) {
        guard count > 0, var element = storage[head] else { return }
        body(&element)
        storage[head] = element
    }

    mutating func mutateLast(_ body: (inout Element) -> Bool) -> Bool {
        guard count > 0 else { return false }
        let index = (head + count - 1) % storage.count
        guard var element = storage[index], body(&element) else { return false }
        storage[index] = element
        return true
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }
}

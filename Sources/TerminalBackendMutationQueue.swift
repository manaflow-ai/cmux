/// Fixed-capacity ring buffer used by the synchronous main-actor ingress.
struct TerminalBackendMutationQueue {
    let capacity: Int

    private var storage: [TerminalBackendQueuedMutation?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }
    var first: TerminalBackendQueuedMutation? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    mutating func append(_ mutation: TerminalBackendQueuedMutation) -> Bool {
        guard count < capacity else { return false }
        let tail = (head + count) % capacity
        storage[tail] = mutation
        count += 1
        return true
    }

    @discardableResult
    mutating func removeFirst() -> TerminalBackendQueuedMutation? {
        guard count > 0 else { return nil }
        let value = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return value
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}

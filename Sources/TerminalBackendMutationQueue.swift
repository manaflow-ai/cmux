/// Fixed-capacity ring buffer used by the synchronous main-actor ingress.
///
/// Presentation-state mutations converge within the current tail segment.
/// Every other mutation is an ordering barrier, so PTY input and user actions
/// retain exact FIFO semantics while resize/focus/visibility/preedit storms
/// consume at most four slots between barriers.
struct TerminalBackendMutationQueue {
    private enum ConvergentMutationKind {
        case focus
        case visibility
        case resize
        case preedit
    }

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
        if let kind = convergentKind(of: mutation.mutation),
           let supersededOffset = supersededOffset(for: kind) {
            remove(atLogicalOffset: supersededOffset)
        } else {
            guard count < capacity else { return false }
        }
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

    private func convergentKind(
        of mutation: TerminalExternalRuntimeMutation
    ) -> ConvergentMutationKind? {
        switch mutation {
        case .focus:
            .focus
        case .visibility:
            .visibility
        case .resize:
            .resize
        case .preedit:
            .preedit
        case .input, .mouse, .bindingAction, .selection, .copyMode, .search,
             .scroll, .reparent, .closeCanonicalTerminal:
            nil
        }
    }

    /// Finds the same convergent state only after the newest strict barrier.
    /// The coalescing invariant bounds this scan to four entries in normal
    /// operation, independent of the queue's configured capacity.
    private func supersededOffset(
        for kind: ConvergentMutationKind
    ) -> Int? {
        guard count > 0 else { return nil }
        for distanceFromTail in 1...count {
            let offset = count - distanceFromTail
            let index = (head + offset) % capacity
            guard let queued = storage[index],
                  let queuedKind = convergentKind(of: queued.mutation) else {
                return nil
            }
            if queuedKind == kind {
                return offset
            }
        }
        return nil
    }

    private mutating func remove(atLogicalOffset offset: Int) {
        precondition(offset >= 0 && offset < count)
        if offset < count - 1 {
            for currentOffset in offset..<(count - 1) {
                let currentIndex = (head + currentOffset) % capacity
                let nextIndex = (head + currentOffset + 1) % capacity
                storage[currentIndex] = storage[nextIndex]
            }
        }
        let tail = (head + count - 1) % capacity
        storage[tail] = nil
        count -= 1
    }
}

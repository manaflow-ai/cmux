/// A replay is useful only while it is complete. Once its budget is exceeded,
/// release it and require a fresh snapshot; keeping only a tail would apply
/// deltas without their turn, permission request or earlier message chunks.
struct AcpmuxReplay<Event> {
    let limit: Int
    private(set) var events: [Event] = []
    private(set) var requiresResync = false

    mutating func append(_ batch: [Event]) {
        guard !requiresResync else { return }
        guard batch.count <= limit - events.count else {
            invalidate()
            return
        }
        events.append(contentsOf: batch)
    }

    mutating func prepend(_ batch: [Event]) {
        guard !requiresResync else { return }
        guard batch.count <= limit - events.count else {
            invalidate()
            return
        }
        events.insert(contentsOf: batch, at: 0)
    }

    /// Inserts a bounded batch at a replay marker (used by reconnect gap repair).
    mutating func insert(contentsOf batch: [Event], at index: Int) {
        guard !requiresResync else { return }
        guard batch.count <= limit - events.count, index >= 0, index <= events.count else {
            invalidate()
            return
        }
        events.insert(contentsOf: batch, at: index)
    }

    mutating func remove(at index: Int) {
        guard !requiresResync, events.indices.contains(index) else { return }
        events.remove(at: index)
    }

    func lastIndex(where predicate: (Event) throws -> Bool) rethrows -> Int? {
        try events.lastIndex(where: predicate)
    }

    mutating func invalidate() {
        events = []
        requiresResync = true
    }
}

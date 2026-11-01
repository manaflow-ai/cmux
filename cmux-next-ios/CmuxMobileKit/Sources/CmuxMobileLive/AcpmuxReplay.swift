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
            events = []
            requiresResync = true
            return
        }
        events.append(contentsOf: batch)
    }
}

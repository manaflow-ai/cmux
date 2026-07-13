/// Mutable coalescing state. Its owner serializes every operation with the
/// existing Ghostty callback lock because enqueue runs off-main while flushes
/// and exact replacement run on the main actor.
final class GhosttyScrollbarUpdateBuffer {
    private var pending: GhosttyScrollbar?
    private var flushScheduled = false

    /// Returns true only when the caller must schedule a main-thread flush.
    func enqueue(_ value: GhosttyScrollbar) -> Bool {
        pending = value
        let needsSchedule = !flushScheduled
        if needsSchedule { flushScheduled = true }
        return needsSchedule
    }

    func takePending() -> GhosttyScrollbar? {
        flushScheduled = false
        defer { pending = nil }
        return pending
    }

    func replaceAndTakeExact(_ value: GhosttyScrollbar) -> GhosttyScrollbar {
        pending = value
        let exact = pending!
        pending = nil
        flushScheduled = false
        return exact
    }
}

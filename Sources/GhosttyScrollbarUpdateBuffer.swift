import Foundation

final class GhosttyScrollbarUpdateBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: GhosttyScrollbar?
    private var flushScheduled = false

    /// Returns true only when the caller must schedule a main-thread flush.
    func enqueue(_ value: GhosttyScrollbar) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        let needsSchedule = !flushScheduled
        if needsSchedule { flushScheduled = true }
        return needsSchedule
    }

    func takePending() -> GhosttyScrollbar? {
        lock.lock()
        defer { lock.unlock() }
        flushScheduled = false
        defer { pending = nil }
        return pending
    }

    func replaceAndTakeExact(_ value: GhosttyScrollbar) -> GhosttyScrollbar {
        lock.lock()
        defer { lock.unlock() }
        pending = value
        let exact = pending!
        pending = nil
        flushScheduled = false
        return exact
    }
}

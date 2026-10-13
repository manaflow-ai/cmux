public import AppKit

/// The keys of one window's pending creations or awaited surface, in typing order.
@MainActor
public final class CreationInputBuffer {
    public struct Ticket: Hashable { fileprivate let id: Int }

    private var events: [NSEvent] = []
    private var pending: [Int: UInt64] = [:]
    private var awaited: Set<UInt64> = []
    private var nextID = 0
    /// When the hold began.
    public let began: ContinuousClock.Instant

    public init(began: ContinuousClock.Instant) { self.began = began }

    public var isResolved: Bool { pending.isEmpty }
    /// A creation opened in this hold: only its reply (or the request timeout) ends it.
    public var holdsCreation: Bool { nextID > 0 }
    public var isEmpty: Bool { events.isEmpty }

    public func open(generation: UInt64) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        return Ticket(id: nextID)
    }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing.
    public func resolve(_ ticket: Ticket, awaitsFocus: Bool) {
        guard let generation = pending.removeValue(forKey: ticket.id) else { return }
        if awaitsFocus { awaited.insert(generation) }
    }

    public func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    public func capture(_ event: NSEvent) { events.append(event) }

    public func prepend(_ earlier: ArraySlice<NSEvent>) { events.insert(contentsOf: earlier, at: 0) }

    public func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events
    }

    /// Calls `expired` after `limit` unless this hold holds a creation by then (its reply ends it).
    public func expire(after limit: Duration, _ expired: @escaping @MainActor (CreationInputBuffer) -> Void) {
        // task-owner: one-shot bound on this hold; a hold that ended first makes it a no-op
        Task { @MainActor [weak self] in
            // wakeup-allow: one-shot bound on a key hold, so a hold whose terminal never shows ends
            try? await Task.sleep(for: limit)
            guard let self, !holdsCreation else { return }
            expired(self)
        }
    }

    /// Whether this hold keeps `event`. A creation's hold keeps every key until its reply; one that
    /// only waits for a selected terminal's surface ends after `limit` (`expiring`), and lets a
    /// chord through while it holds nothing (held Ctrl-Tab makes no surface for a tab it passed).
    public func holds(_ event: NSEvent, limit: Duration, expiring: Bool) -> Bool {
        guard !holdsCreation else { return true }
        if expiring, ContinuousClock.now - began >= limit { return false }
        return !(isEmpty && !event.modifierFlags.intersection([.command, .control]).isEmpty)
    }
}

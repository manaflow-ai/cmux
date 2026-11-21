import CMUXAgentLaunch
import Foundation

/// The Claude panes waiting for a session priority restart, oldest first.
///
/// It holds at most one entry per pane. Queueing a pane again replaces its target and keeps its
/// turn, so a pane whose target changed while it waited is restarted once, for the newest one.
/// A removed pane gives up its turn; queued again, it waits at the back.
///
/// Entries are keyed by pane and their turns kept in a FIFO with a head index, so queueing,
/// replacing, removing and taking the next pane cost amortized O(1) however many panes wait.
struct SessionPriorityApplyQueue: Equatable {
    /// One pane waiting for its restart.
    struct Entry: Equatable {
        var panelId: UUID
        /// The workspace the pane was in when it was queued. The pane may move before its turn,
        /// so the drain looks it up again.
        var workspaceId: UUID
        var target: SessionPriorityTarget
    }

    /// A waiting pane's entry and the ticket of its turn.
    private struct Waiting {
        var entry: Entry
        var ticket: Int
    }

    /// One place in line. It is spent once taken, and given up once its pane is removed (the
    /// pane's ticket then no longer matches).
    private struct Turn {
        var panelId: UUID
        var ticket: Int
    }

    private var waiting: [UUID: Waiting] = [:]
    /// Turns in queue order; those before `head` are spent.
    private var turns: [Turn] = []
    private var head = 0
    private var nextTicket = 0

    var isEmpty: Bool { waiting.isEmpty }

    /// Queues the pane, or replaces its pending entry in place.
    mutating func enqueue(panelId: UUID, workspaceId: UUID, target: SessionPriorityTarget) {
        let entry = Entry(panelId: panelId, workspaceId: workspaceId, target: target)
        if waiting[panelId] != nil {
            waiting[panelId]?.entry = entry
            return
        }
        waiting[panelId] = Waiting(entry: entry, ticket: nextTicket)
        turns.append(Turn(panelId: panelId, ticket: nextTicket))
        nextTicket += 1
    }

    /// Removes and returns the oldest entry.
    mutating func next() -> Entry? {
        defer { compactIfNeeded() }
        while head < turns.count {
            let turn = turns[head]
            head += 1
            if isLive(turn) {
                return waiting.removeValue(forKey: turn.panelId)?.entry
            }
        }
        return nil
    }

    mutating func remove(panelId: UUID) {
        guard waiting.removeValue(forKey: panelId) != nil else { return }
        compactIfNeeded()
    }

    mutating func removeAll() {
        waiting.removeAll()
        turns.removeAll()
        head = 0
    }

    /// Equal when the same entries wait in the same order, however each queue got there.
    static func == (lhs: SessionPriorityApplyQueue, rhs: SessionPriorityApplyQueue) -> Bool {
        lhs.pendingEntries == rhs.pendingEntries
    }

    /// The waiting entries, oldest first.
    private var pendingEntries: [Entry] {
        turns[head...].compactMap { isLive($0) ? waiting[$0.panelId]?.entry : nil }
    }

    private func isLive(_ turn: Turn) -> Bool {
        waiting[turn.panelId]?.ticket == turn.ticket
    }

    /// Drops spent and given-up turns once they outnumber the waiting panes, so `turns` stays
    /// within a constant factor of the queue: each dropped turn was paid for by the operation
    /// that spent or gave it up.
    private mutating func compactIfNeeded() {
        guard turns.count > 2 * waiting.count + 16 else { return }
        turns = turns[head...].filter { isLive($0) }
        head = 0
    }
}

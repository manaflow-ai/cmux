import CMUXAgentLaunch
import Foundation

/// The Claude panes waiting for a session priority restart, oldest first.
///
/// It holds at most one entry per pane. Queueing a pane again replaces its target and keeps its
/// turn, so a pane whose target changed while it waited is restarted once, for the newest one.
struct SessionPriorityApplyQueue: Equatable {
    /// One pane waiting for its restart.
    struct Entry: Equatable {
        var panelId: UUID
        /// The workspace the pane was in when it was queued. The pane may move before its turn,
        /// so the drain looks it up again.
        var workspaceId: UUID
        var target: SessionPriorityTarget
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Queues the pane, or replaces its pending entry in place.
    mutating func enqueue(panelId: UUID, workspaceId: UUID, target: SessionPriorityTarget) {
        let entry = Entry(panelId: panelId, workspaceId: workspaceId, target: target)
        if let index = entries.firstIndex(where: { $0.panelId == panelId }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// Removes and returns the oldest entry.
    mutating func next() -> Entry? {
        entries.isEmpty ? nil : entries.removeFirst()
    }

    mutating func remove(panelId: UUID) {
        entries.removeAll { $0.panelId == panelId }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

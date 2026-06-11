import AppKit
import Bonsplit
import CMUXAgentLaunch
import Darwin
import Foundation
import Observation
import os
import SQLite3


/// Process-wide registry that pairs a synthetic drag UUID with a SessionEntry.
/// Used to forward sessions through bonsplit's external-tab-drop hook (which only
/// carries UUIDs in its payload). Workspace.handleExternalTabDrop consults this
/// to decide whether a drop should spawn a brand new terminal vs. move an existing tab.
@MainActor
final class SessionDragRegistry {
    static let shared = SessionDragRegistry()

    private var pending: [UUID: SessionEntry] = [:]

    func register(_ entry: SessionEntry) -> UUID {
        let id = UUID()
        pending[id] = entry
        // Auto-expire so a cancelled drag doesn't leak forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.pending.removeValue(forKey: id)
        }
        return id
    }

    func consume(id: UUID) -> SessionEntry? {
        pending.removeValue(forKey: id)
    }
}

// MARK: - Store

/// Owns the "which section is currently being dragged" bit, separate from
/// `SessionIndexStore`. Isolating this means drag start/end does not
/// invalidate views observing the data store, so rows and gaps don't
/// re-render every time a drag begins or clears.
@MainActor
@Observable
final class SessionDragCoordinator {
    var draggedKey: SectionKey? = nil
}


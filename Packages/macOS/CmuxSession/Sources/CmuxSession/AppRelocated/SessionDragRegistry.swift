import Foundation

/// Registry that pairs a synthetic drag UUID with a `SessionEntry`.
///
/// Used to forward sessions through bonsplit's external-tab-drop hook (which only
/// carries UUIDs in its payload). `Workspace.handleExternalTabDrop` consults this
/// to decide whether a drop should spawn a brand new terminal vs. move an
/// existing tab.
///
/// This is a constructor-injected owner held at the app composition root (no
/// `static let shared` singleton). The producer (the Sessions sidebar drag
/// provider) registers an entry and the consumer (`Workspace`'s drop hosting)
/// consumes it; both reach the same instance through the injected owner rather
/// than a process-wide accessor.
@MainActor
final class SessionDragRegistry {
    private var pending: [UUID: SessionEntry] = [:]

    init() {}

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

import Foundation

/// Process-local capability registry for the one active Vault drag.
///
/// Pane-transfer payloads intentionally carry only an opaque UUID. Shared pane
/// targets resolve that UUID here while the AppKit drag source is alive.
@MainActor
final class SessionDragRegistry {
    static let shared = SessionDragRegistry()

    private enum State {
        case idle
        case active(id: UUID, entry: SessionEntry)
    }

    private var state: State = .idle

    func register(_ entry: SessionEntry) -> UUID {
        let id = UUID()
        // AppKit permits only one process-local drag at a time. Replacing an
        // abandoned test registration also invalidates its residual payload.
        state = .active(id: id, entry: entry)
        return id
    }

    func contains(id: UUID) -> Bool {
        entry(id: id) != nil
    }

    func entry(id: UUID) -> SessionEntry? {
        guard case .active(let activeID, let entry) = state,
              activeID == id else { return nil }
        return entry
    }

    func consume(id: UUID) -> SessionEntry? {
        guard let entry = entry(id: id) else { return nil }
        state = .idle
        return entry
    }

    func discard(id: UUID) {
        guard contains(id: id) else { return }
        state = .idle
    }
}

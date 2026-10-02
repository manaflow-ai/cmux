/// The pending effective grid for a terminal whose local scroll position is
/// currently content anchored. A daemon echo may arrive after the user has
/// moved the viewport, so changing the Ghostty grid at that point would
/// reflow the row space underneath the visible rows.
struct TerminalEffectiveGridScrollGate: Equatable, Sendable {
    enum Update: Equatable, Sendable {
        case natural
        case remoteGrid(columns: Int, rows: Int)
    }

    private(set) var pending: Update?

    /// Submit one update. While an undocked local anchor exists, retain only
    /// the newest update. A safe submission applies immediately and retires a
    /// stale deferred update.
    mutating func submit(
        _ update: Update,
        anchorUndocked: Bool
    ) -> Update? {
        guard update.isValid else { return nil }
        guard anchorUndocked else {
            pending = nil
            return update
        }
        pending = update
        return nil
    }

    /// Releases the latest deferred update once the local viewport is at the
    /// tail. Until then, the Ghostty row space stays unchanged.
    mutating func flushIfSafe(anchorUndocked: Bool) -> Update? {
        guard !anchorUndocked, let pending else { return nil }
        self.pending = nil
        return pending
    }

    mutating func reset() {
        pending = nil
    }
}

private extension TerminalEffectiveGridScrollGate.Update {
    var isValid: Bool {
        switch self {
        case .natural:
            true
        case .remoteGrid(let columns, let rows):
            columns > 0 && rows > 0
        }
    }
}

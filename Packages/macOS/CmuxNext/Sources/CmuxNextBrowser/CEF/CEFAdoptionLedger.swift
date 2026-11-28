/// Browsers Chromium created itself that wait for a pane (a window being
/// created, or the deferred move into the shown pane), and browsers that
/// closed before cmux registered them. A browser that closed while waiting
/// must never be adopted: its tab would be a ghost with no page.
nonisolated struct CEFAdoptionLedger: Equatable, Sendable {
    /// Waiting for their window's pane (in creation order).
    private(set) var waiting: [Orphan] = []
    /// Closed before registration. Chromium never reuses browser ids.
    private(set) var closed: Set<Int32> = []

    mutating func enqueue(_ orphan: Orphan) {
        guard !closed.contains(orphan.browser) else { return }
        waiting.append(orphan)
    }

    /// Takes every waiting browser (the caller re-queues those still waiting).
    mutating func takeWaiting() -> [Orphan] {
        defer { waiting.removeAll() }
        return waiting
    }

    /// `browser` closed and no tab was registered for it.
    mutating func closedUnregistered(_ browser: Int32) {
        closed.insert(browser)
        waiting.removeAll { $0.browser == browser }
    }

    func isClosed(_ browser: Int32) -> Bool { closed.contains(browser) }
}

nonisolated struct Orphan: Equatable, Sendable {
    var browser: Int32
    var window: Int32
}

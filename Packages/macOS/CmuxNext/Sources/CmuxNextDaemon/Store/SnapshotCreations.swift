import Foundation

/// What a snapshot tells the creates that still wait. A tree holds everything that the daemon
/// did, and the store skips the events that the tree covers, so the tree stands in for them.
enum SnapshotCreations {
    /// Runs in a snapshot apply with the overlay lifted (the records hold only the daemon's tabs).
    @MainActor static func note(in store: DaemonStore) {
        ProvisionalSplit.noteDaemonPanes(in: store)
        noteDaemonTerminals(in: store)
    }

    /// A snapshot that holds a pending terminal create's daemon tab counts as that tab's raw
    /// `tab-added` (``ProvisionalTab/matched(_:in:)``): a resync can bring the tree before that
    /// event and before the reply, and the store then skips the event. The tab with the terminal
    /// id that the stand-in named is that create's, so the stand-in gives way to it in this apply
    /// and the two never show side by side.
    ///
    /// A page or a chat has no such id: nothing in a tree names its create, so its daemon tab
    /// from a snapshot still shows beside the stand-in until the reply.
    @MainActor private static func noteDaemonTerminals(in store: DaemonStore) {
        guard !store.intentLog.isEmpty else { return }
        for entry in store.intentLog.entries where !entry.createdConfirmed {
            guard case .createTab(_, let provisional) = entry.kind, provisional.kind == .pty,
                  let terminal = provisional.terminalID, let tab = store.index.tabsByTerminal[terminal],
                  !ProvisionalTab.isProvisional(surface: tab.surface) else { continue }
            store.intentLog.noteCreated(entry.transaction, surface: tab.surface)
        }
    }
}

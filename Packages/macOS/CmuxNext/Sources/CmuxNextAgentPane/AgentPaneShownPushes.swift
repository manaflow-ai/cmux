import AppKit

/// App-wide state pushes to one agent pane's page (the New Tab cards' device chats, Now Playing):
/// each is the whole latest value, so only the newest matters. A change waits for the next turn,
/// and several changes in one turn send once; a pane nobody can see sends nothing until it shows
/// (``AgentPaneVisibilityProbe``), and then sends the value of that moment.
///
/// Every push is a page script: on a Chromium page a DevTools `Runtime.evaluate` on the main
/// thread (ChromiumPageHostBridge). The Chats feed set every pane's device chats on each change of
/// the index, a few per turn while agents ran, so twenty open chats, most of them behind other tabs,
/// cost twenty evaluates per change (11% of the main thread in a NIGHTLY sample, 2026-11-03).
/// Kept off ``AgentPaneView``, whose type is at its size limit.
@MainActor final class AgentPaneShownPushes {
    /// Whether nobody can see the pane (``AgentPaneFramePacer/nobodySees(_:)``; tests replace it).
    var isHidden: @MainActor (AgentPaneView) -> Bool = AgentPaneFramePacer.nobodySees
    /// Runs the flush on a later turn (tests replace it).
    var nextTurn: @MainActor (@escaping @MainActor () -> Void) -> Void = { work in
        // task-owner: one coalesced flush of a pane's state pushes; it runs once, on the main actor
        Task { @MainActor in work() }
    }
    /// The pushes owed, by name, in the order first owed; each reads its value when it runs.
    private var owed: [(name: String, send: @MainActor (AgentPaneView) -> Void)] = []
    private var scheduled = false
    private var probe: AgentPaneVisibilityProbe?

    /// Owes `name`'s push to `view`'s page: `send` runs once, on a later turn while `view` is seen,
    /// replacing any `name` push still owed.
    func push(_ name: String, to view: AgentPaneView, _ send: @escaping @MainActor (AgentPaneView) -> Void) {
        if let index = owed.firstIndex(where: { $0.name == name }) {
            owed[index].send = send
        } else {
            owed.append((name, send))
        }
        schedule(view)
    }

    /// Names of the pushes owed (tests).
    var owedNames: [String] { owed.map(\.name) }

    private func schedule(_ view: AgentPaneView) {
        guard !scheduled, probe == nil else { return }
        scheduled = true
        nextTurn { [weak self, weak view] in
            guard let self else { return }
            scheduled = false
            guard let view else { return owed.removeAll() }
            flush(view)
        }
    }

    /// Sends what is owed when `view` is seen, else waits for it to show.
    func flush(_ view: AgentPaneView) {
        guard !owed.isEmpty else { return }
        guard !isHidden(view) else { return watch(view) }
        probe?.removeFromSuperview()
        probe = nil
        let sends = owed
        owed.removeAll()
        for push in sends { push.send(view) }
    }

    private func watch(_ view: AgentPaneView) {
        guard probe == nil else { return }
        let probe = AgentPaneVisibilityProbe(frame: .zero)
        probe.onChange = { [weak self, weak view] in
            guard let self, let view else { return }
            flush(view)
        }
        // Set first: AppKit may call the probe back inside addSubview.
        self.probe = probe
        view.addSubview(probe)
    }
}

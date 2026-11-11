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

extension AgentPaneView {
    /// Runs `work` once while someone can see this pane: on a later turn when it shows now, else
    /// when it shows. Work of the same `name` still owed is replaced, so only the newest runs. For
    /// work whose result only a person at this chat uses (the diff warm of a turn's end): as Chrome
    /// holds the work of a page that is not shown, a chat behind another tab asks nothing of the
    /// session host for it.
    public func whenSeen(_ name: String, _ work: @escaping @MainActor () -> Void) {
        // NOT FOR MERGE: the behaviour of the base (the turn's end ran the diff warm in its own
        // turn, seen or not), so that AgentPaneWhenSeenTests fails at its asserts.
        work()
    }
}

extension Sequence<AgentPaneView> {
    /// Runs `work` once when someone can see one of these panes that shows acpmux session
    /// `session`: on a later turn when one shows now, else when the first of them shows
    /// (``AgentPaneView/whenSeen(_:_:)``). A session with no pane owes nothing.
    ///
    /// The diff warm of a turn's end goes through here: about 50 agents that end turns in bursts
    /// each ran a full-patch `git.diff` nobody waited for, in front of the git reads of the view
    /// the person looked at.
    @MainActor public func whenSeen(session: String, _ name: String, _ work: @escaping @MainActor () -> Void) {
        let owed = AgentPaneOwedOnce(work)
        for view in self where view.model.sessionId == session {
            view.whenSeen(name) { owed.run() }
        }
    }
}

/// One piece of work owed to several panes of one chat: the first pane seen runs it.
@MainActor private final class AgentPaneOwedOnce {
    private var work: (@MainActor () -> Void)?

    init(_ work: @escaping @MainActor () -> Void) { self.work = work }

    func run() {
        let owed = work
        work = nil
        owed?()
    }
}

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
    /// The pane's page moved to another chat in place (``AgentPaneModel/adoptSession(_:)``): the
    /// owner of the chats' owed work hands the pane the new chat's (``AgentPaneOwedWork``).
    var onSessionChange: (@MainActor () -> Void)?

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
        shownPushes.push(name, to: self) { _ in work() }
    }
}

/// Work owed to a chat until someone can see one of its panes.
///
/// The debt is the chat's, not a pane's. A chat nobody looks at often has no pane: its page was
/// released to save memory, or no tab shows it yet. The pane made when the person comes to the
/// chat takes the debt (``hand(to:)``), and so does a pane whose page moves to the chat in place.
/// Each pane of the chat is asked (``AgentPaneView/whenSeen(_:_:)``), and the first one seen
/// that still shows the chat runs the work, once.
///
/// The diff warm of a turn's end goes through here: about 50 agents that end turns in bursts
/// each ran a full-patch `git.diff` nobody waited for, in front of the git reads of the view
/// the person looked at.
///
/// Bound: one piece of work for each chat and name, the newest; ``limit`` pieces at most, the
/// oldest dropped first. A dropped diff warm costs that chat one diff tab that opens with no warm.
/// The app makes one (its services own it): the turn-end observer owes, the tab store hands the
/// debts to the panes it makes.
@MainActor public final class AgentPaneOwedWork {
    static let limit = 256
    private var owed: [(session: String, name: String, work: @MainActor () -> Void)] = [] {
        didSet { sessions = Set(owed.map(\.session)) }
    }
    /// The chats that owe work, so a pane of a chat that owes nothing costs one lookup.
    private var sessions: Set<String> = []

    public init() {}

    /// The sessions that owe work, oldest debt first (tests).
    var owedSessions: [String] { owed.map(\.session) }

    /// Owes `work` to acpmux session `session`, in place of its `name` work still owed: it runs once,
    /// on a later turn when a pane in `views` shows the chat to someone now, else when a pane of the
    /// chat shows, one made later too.
    public func owe(session: String, _ name: String, in views: some Sequence<AgentPaneView>, _ work: @escaping @MainActor () -> Void) {
        owed.removeAll { $0.session == session && $0.name == name }
        owed.append((session, name, work))
        if owed.count > Self.limit { owed.removeFirst(owed.count - Self.limit) }
        hand(to: views)
    }

    /// Asks each pane in `views` whose chat owes work to run it when someone can see the pane: the
    /// tab store calls it when it made a pane. A pane it saw asks again by itself when its page
    /// moves to another chat. Work runs only in a pane that still shows the chat that owes it; a
    /// pane that left the chat leaves the debt for the chat's next pane.
    public func hand(to views: some Sequence<AgentPaneView>) {
        for view in views {
            view.shownPushes.onSessionChange = { [weak self, weak view] in
                guard let self, let view else { return }
                hand(to: CollectionOfOne(view))
            }
            guard let session = view.model.sessionId, sessions.contains(session) else { continue }
            for name in owed.filter({ $0.session == session }).map(\.name) {
                view.whenSeen(name) { [weak self, weak view] in
                    guard view?.model.sessionId == session else { return }
                    self?.run(session, name)
                }
            }
        }
    }

    /// Runs and forgets the work `session` owes under `name`; a second pane's call finds nothing.
    private func run(_ session: String, _ name: String) {
        guard let index = owed.firstIndex(where: { $0.session == session && $0.name == name }) else { return }
        owed.remove(at: index).work()
    }
}

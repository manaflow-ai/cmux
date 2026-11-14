import CmuxNextWakeups

/// A closed agent page leaves the view tree at once (cheap); its teardown
/// (WKWebView stop and unload, bridge and observer removal) runs at a quiet
/// moment after the close, so a Cmd-W frame never pays for it (R81). A closed chat of this Mac
/// is kept whole for 30 s first (``ClosedPageKeeper``, at most two pages): Reopen Closed takes it
/// back loaded and drawn.
@MainActor
public final class AgentPageRetirer {
    public static let delay: Duration = .milliseconds(500)
    private var retiring: [AgentPaneView] = []
    private let timer = DemandTimer(owner: "AgentPageRetirer")
    /// The app's bench spans around the detach and the teardown (`agentPane.detach`, `agentPane.close`).
    private let measure: @MainActor (String, () -> Void) -> Void
    private lazy var kept = ClosedPageKeeper<AgentPaneView>(limit: 2, keepFor: .seconds(30), owner: "AgentPageRetirer.keep") { [weak self] in
        self?.teardown($0)
    }

    public init(measure: @escaping @MainActor (String, () -> Void) -> Void = { _, body in body() }) {
        self.measure = measure
    }

    /// The kept pages, under keys no tab has: a quit asks them too (``AgentPaneRelaunchWake/collect(held:pages:live:limit:)``),
    /// so prompts they hold go into their chats' drafts.
    public var keptPages: [(key: String, view: AgentPaneView)] { kept.pages.map { ("kept:\($0.session)", $0.page) } }

    /// The kept page of closed chat `session`, taken back.
    public func takeKept(_ session: String) -> AgentPaneView? { kept.take(session) }

    /// Retires `view`; a chat page of this Mac showing `session` is kept first.
    public func retire(_ view: AgentPaneView, keeping session: String? = nil) {
        // A closed New Tab page drops the chat a chip pick started behind it; the page stays alive
        // until the teardown below, long enough to send the discard.
        view.topBar.discardUnsentChat()
        measure("agentPane.detach") { view.removeFromSuperview() }
        // A page that is dictating is not kept: its microphone session belongs to the closed tab.
        if let session, view.dictation.phase.isStartable {
            view.quietForKeep()
            if kept.keep(view, for: session) { return }
        }
        teardown(view)
    }

    private func teardown(_ view: AgentPaneView) {
        retiring.append(view)
        timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.flush() }
    }

    private func flush() {
        let views = retiring
        retiring.removeAll()
        for view in views { view.releaseHeldPrompts { [measure] retired in measure("agentPane.close") { retired.close() } } }
    }
}

extension AgentPaneView {
    /// What a close ends that a kept closed page must not keep doing: its shell runs (commands that
    /// change files) and read aloud. Prompts it holds for a folder trust answer stay in it as they
    /// were, so a reopen shows them unchanged; its teardown or a quit (``AgentPageRetirer/keptPages``)
    /// puts them into their chats' drafts, as a close does. The page stays loaded and drawn.
    func quietForKeep() {
        model.shell.terminateAll()
        model.readAloud?.stop(owner: model)
    }
}

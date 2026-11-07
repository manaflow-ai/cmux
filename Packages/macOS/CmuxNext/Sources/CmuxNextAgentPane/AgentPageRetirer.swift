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

    /// The kept page of closed chat `session`, taken back.
    public func takeKept(_ session: String) -> AgentPaneView? { kept.take(session) }

    /// Retires `view`; a chat page of this Mac showing `session` is kept first.
    public func retire(_ view: AgentPaneView, keeping session: String? = nil) {
        // A closed New Tab page drops the chat a chip pick started behind it; the page stays alive
        // until the teardown below, long enough to send the discard.
        view.topBar.discardUnsentChat()
        measure("agentPane.detach") { view.removeFromSuperview() }
        if let session, kept.keep(view, for: session) { return }
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

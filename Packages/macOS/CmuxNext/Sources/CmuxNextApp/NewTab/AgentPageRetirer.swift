import CmuxNextAgentPane
import CmuxNextWakeups

/// A closed agent page leaves the view tree at once (cheap); its teardown
/// (WKWebView stop and unload, bridge and observer removal) runs at a quiet
/// moment after the close, so a Cmd-W frame never pays for it (R81). Nobody
/// sees the teardown: one ``MainDeadline`` in the background class, so it also
/// waits behind the person's input and frames.
@MainActor
final class AgentPageRetirer {
    static let delay: Duration = .milliseconds(500)
    private var retiring: [AgentPaneView] = []
    private let deadline: MainDeadline

    /// - Parameter deadlines: The deadline placer on the app's main-thread scheduler.
    init(deadlines: MainDeadlineScheduler) {
        deadline = MainDeadline(owner: "AgentPageRetirer", workClass: .background, scheduler: deadlines)
    }

    func retire(_ view: AgentPaneView) {
        // A closed New Tab page drops the chat a chip pick started behind it; the page stays alive
        // until the teardown below, long enough to send the discard.
        view.topBar.discardUnsentChat()
        BenchSpans.measure("agentPane.detach") { view.removeFromSuperview() }
        retiring.append(view)
        deadline.schedule(after: Self.delay) { [weak self] in self?.flush() }
    }

    private func flush() {
        let views = retiring
        retiring.removeAll()
        for view in views { BenchSpans.measure("agentPane.close") { view.close() } }
    }
}

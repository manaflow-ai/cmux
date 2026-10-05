import CmuxNextAgentPane
import CmuxNextWakeups

/// A closed agent page leaves the view tree at once (cheap); its teardown
/// (WKWebView stop and unload, bridge and observer removal) runs at a quiet
/// moment after the close, so a Cmd-W frame never pays for it (R81).
@MainActor
final class AgentPageRetirer {
    static let delay: Duration = .milliseconds(500)
    private var retiring: [AgentPaneView] = []
    private let timer = DemandTimer(owner: "AgentPageRetirer")

    func retire(_ view: AgentPaneView) {
        BenchSpans.measure("agentPane.detach") { view.removeFromSuperview() }
        retiring.append(view)
        timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.flush() }
    }

    private func flush() {
        let views = retiring
        retiring.removeAll()
        for view in views { BenchSpans.measure("agentPane.close") { view.close() } }
    }
}

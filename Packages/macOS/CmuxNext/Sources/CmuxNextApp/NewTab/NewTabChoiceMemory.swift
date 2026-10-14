import AppKit
import CmuxNextAgentPane
import CmuxNextSettings

/// The agent last picked on the new tab screen, kept on this Mac across
/// relaunches (decision Q3: app-local memory; one input without a mode,
/// R86). Client view state, so it never reaches the daemon.
/// Also the harness and model picked last, anywhere and per folder (`AgentPaneLastPicks`): the
/// agent pages' own storage ends with the launch, so the app keeps them.
/// Also the template each window's dots last picked (cx-l1jv), for that
/// window's next pages; it lives as long as the window.
@MainActor
final class NewTabChoiceMemory {
    private static let agentKey = "newTab.lastAgent"
    private static let picksKey = "newTab.lastPicks"
    private static let harnessHintKey = "newTab.harnessHintDismissed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var agent: String? { defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 } }

    var picks: AgentPaneLastPicks? {
        defaults.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode(AgentPaneLastPicks.self, from: $0) }
    }

    /// Integrate a harness was dismissed on a New Tab page (Leo 2026-10-12: the dismissal sticks).
    var harnessHintDismissed: Bool { defaults.bool(forKey: Self.harnessHintKey) }

    /// A value the page should never send (empty, too long) is ignored. The model, when the pick
    /// names one, is remembered on the agent for every folder and for its folder.
    func remember(_ pick: AgentPaneRememberedPick) {
        if pick.dismissesHarnessHint { defaults.set(true, forKey: Self.harnessHintKey) }
        guard !pick.agent.isEmpty, pick.agent.count <= 128 else { return }
        defaults.set(pick.agent, forKey: Self.agentKey)
        // The agent's own "default" is not a pick.
        guard let model = pick.model, model != "default" else { return }
        var picks = picks ?? AgentPaneLastPicks()
        picks.record(.init(harness: pick.agent, model: model), folder: pick.folder)
        if let data = try? JSONEncoder().encode(picks) { defaults.set(data, forKey: Self.picksKey) }
    }
}

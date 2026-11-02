import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import Observation

/// The agent last picked on the new tab screen, kept on this Mac across
/// relaunches (decision Q3: app-local memory; one input without a mode,
/// R86). Client view state, so it never reaches the daemon; the iPhone host hands the
/// last picks to acpmux (memory only) so a phone's New Agent Chat starts where this
/// Mac's does (`_acpmux/new_chat_picks_set`).
/// Also the harness and model picked last, anywhere and per folder (`AgentPaneLastPicks`): the
/// agent pages' own storage ends with the launch, so the app keeps them.
/// Also the template each window's dots last picked (cx-l1jv), for that
/// window's next pages; it lives as long as the window.
@MainActor
@Observable
final class NewTabChoiceMemory {
    private static let agentKey = "newTab.lastAgent"
    private static let picksKey = "newTab.lastPicks"
    private static let harnessHintKey = "newTab.harnessHintDismissed"
    private static let startedProjectKey = "newTab.startedProject"
    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped by each remembered pick, so an observer (the iPhone host's sync of the last
    /// picks to acpmux) reads ``agent`` and ``picks`` again.
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var agent: String? {
        _ = revision
        return defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    var picks: AgentPaneLastPicks? {
        _ = revision
        return defaults.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode(AgentPaneLastPicks.self, from: $0) }
    }

    /// Integrate a harness was dismissed on a New Tab page (Leo 2026-10-12: the dismissal sticks).
    var harnessHintDismissed: Bool { defaults.bool(forKey: Self.harnessHintKey) }

    /// The project of the chat the person last picked and started from a composer (Leo 2026-10-21:
    /// "your recently PICKED AND STARTED CHAT"). Only a page's `started` writes it; workspaces and
    /// chats agents, the CLI or the socket make never do.
    var startedProject: String? {
        _ = revision
        return defaults.string(forKey: Self.startedProjectKey).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// A value the page should never send (empty, too long) is ignored. Every agent pick, also on its
    /// own default, is the next New Tab's; one naming no model keeps the last pick's model on that agent.
    func remember(_ pick: AgentPaneRememberedPick) {
        if pick.dismissesHarnessHint { defaults.set(true, forKey: Self.harnessHintKey) }
        if let started = pick.started, started.hasPrefix("/"), started.count <= 4096 {
            defaults.set(started, forKey: Self.startedProjectKey)
            revision += 1
        }
        guard !pick.agent.isEmpty, pick.agent.count <= 128 else { return }
        defaults.set(pick.agent, forKey: Self.agentKey)
        defer { revision += 1 }
        var picks = picks ?? AgentPaneLastPicks()
        let model = pick.model ?? picks.lastModel(harness: pick.agent, folder: pick.folder) ?? AgentPaneLastPicks.defaultModel
        picks.record(.init(harness: pick.agent, model: model), folder: pick.folder)
        if let data = try? JSONEncoder().encode(picks) { defaults.set(data, forKey: Self.picksKey) }
    }
}

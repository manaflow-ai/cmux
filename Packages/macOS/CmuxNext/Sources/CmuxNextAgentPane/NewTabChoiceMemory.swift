public import Foundation
public import Observation

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
public final class NewTabChoiceMemory {
    private static let agentKey = "newTab.lastAgent"
    private static let picksKey = "newTab.lastPicks"
    private static let harnessHintKey = "newTab.harnessHintDismissed"
    private static let startedProjectKey = "newTab.startedProject"
    private static let cloudStartedProjectKey = "newTab.cloudStartedProject"
    @ObservationIgnored private let defaults: UserDefaults
    /// Bumped by each remembered pick, so an observer (the iPhone host's sync of the last
    /// picks to acpmux) reads ``agent`` and ``picks`` again.
    public private(set) var revision = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var agent: String? {
        _ = revision
        return defaults.string(forKey: Self.agentKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var picks: AgentPaneLastPicks? {
        _ = revision
        // main-actor-ok: a UserDefaults blob of at most AgentPaneLastPicks.maxFolders (50) folder picks plus one global pick.
        return defaults.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode(AgentPaneLastPicks.self, from: $0) }
    }

    /// Integrate a harness was dismissed on a New Tab page (Leo 2026-10-12: the dismissal sticks).
    public var harnessHintDismissed: Bool { defaults.bool(forKey: Self.harnessHintKey) }

    /// The project of the chat the person last picked and started from a composer (Leo 2026-10-21:
    /// "your recently PICKED AND STARTED CHAT"). Only a page's `started` writes it; workspaces and
    /// chats agents, the CLI or the socket make never do.
    public var startedProject: String? {
        _ = revision
        return defaults.string(forKey: Self.startedProjectKey).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }

    /// The folder or GitHub repository (`github:owner/name`) the person last started a Cloud chat in (`newTab.remember`
    /// `cloudStarted`): a page with Cloud picked starts there, apart from This Mac's ``startedProject`` (cmux#53226).
    public var cloudStartedProject: String? {
        _ = revision
        return defaults.string(forKey: Self.cloudStartedProjectKey).flatMap { AgentPaneRememberedPick.isCloudPick($0) ? $0 : nil }
    }

    /// A value the page should never send (empty, too long) is ignored. Every agent pick, also on its
    /// own default, is the next New Tab's; one naming no model keeps the last pick's model on that agent.
    public func remember(_ pick: AgentPaneRememberedPick) {
        if pick.dismissesHarnessHint { defaults.set(true, forKey: Self.harnessHintKey) }
        if let started = pick.started, started.hasPrefix("/"), started.count <= 4096 {
            defaults.set(started, forKey: Self.startedProjectKey)
            revision += 1
        }
        if let cloud = pick.cloudStarted, AgentPaneRememberedPick.isCloudPick(cloud) {
            defaults.set(cloud, forKey: Self.cloudStartedProjectKey)
            revision += 1
        }
        guard !pick.agent.isEmpty, pick.agent.count <= 128 else { return }
        defer { revision += 1 }
        var picks = picks ?? AgentPaneLastPicks()
        if pick.forCloud {
            // Cloud's own bucket: this Mac's last agent and picks stay as they were.
            let model = pick.model ?? (picks.cloud?.harness == pick.agent ? picks.cloud?.model : nil) ?? AgentPaneLastPicks.defaultModel
            picks.cloud = .init(harness: pick.agent, model: model)
            // main-actor-ok: at most AgentPaneLastPicks.maxFolders (50) folder picks plus two global picks.
            if let data = try? JSONEncoder().encode(picks) { defaults.set(data, forKey: Self.picksKey) }
            return
        }
        defaults.set(pick.agent, forKey: Self.agentKey)
        let model = pick.model ?? picks.lastModel(harness: pick.agent, folder: pick.folder) ?? AgentPaneLastPicks.defaultModel
        picks.record(.init(harness: pick.agent, model: model), folder: pick.folder)
        // main-actor-ok: at most AgentPaneLastPicks.maxFolders (50) folder picks plus one global pick.
        if let data = try? JSONEncoder().encode(picks) { defaults.set(data, forKey: Self.picksKey) }
    }
}

public extension AgentPaneNewTab {
    /// The page starting where the person last started a chat, per mode: This Mac's project and Cloud's own last
    /// pick (cmux#53226). nil (another machine's page) names neither.
    @MainActor func startingIn(_ choices: NewTabChoiceMemory?) -> AgentPaneNewTab {
        startingIn(choices?.startedProject, cloud: choices?.cloudStartedProject)
    }
}

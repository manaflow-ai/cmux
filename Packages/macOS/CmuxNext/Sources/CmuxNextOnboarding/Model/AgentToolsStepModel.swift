public import CmuxNextAgentIntegrations
import Foundation
public import Observation

/// The cmux Tools step (and the setup card's row): asks whether agents the person starts in cmux
/// (its terminals, agent chats) get cmux's MCP server, Computer Use included, lists the agents
/// found, and keeps the answer. Turn On sets `on`; Not Now sets `off`. Either only writes the
/// answer: cmux gives its server through each agent's launch and never writes an agent's own
/// config. Nothing is written until the person answers (Aziz, 2026-11-10: "prevent overstepping on
/// a user's setup").
@MainActor
@Observable
public final class AgentToolsStepModel {
    /// The coding agents found on this Mac, in `cmux setup mcp`'s order.
    public private(set) var agents: [AgentToolsAgent] = []
    /// The first read answered (an empty list then says none was found).
    public private(set) var loaded = false
    /// The answer: this model's own once the person answered here, else the settings file's now (read
    /// live, so an answer given in another window or in Settings shows here too).
    public var choice: AgentToolsChoice {
        if answered { return localChoice }
        return source?.agentToolsChoice() ?? localChoice
    }

    /// The answer given here (or read at start without a source).
    private var localChoice: AgentToolsChoice = .ask
    /// Add (or a Settings Remove) runs.
    public private(set) var applying = false
    /// The last run could not set up every agent (or did not run).
    public private(set) var failed = false
    /// The person answered in this window (the step then shows what it did, and Done).
    public private(set) var answered = false

    @ObservationIgnored public let source: (any AgentToolsSource)?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var run: Task<Void, Never>?

    public init(source: (any AgentToolsSource)?) {
        self.source = source
    }

    /// Reads the answer and the agents (nothing is written).
    public func start() {
        guard let source else {
            loaded = true
            return
        }
        localChoice = source.agentToolsChoice()
        refresh()
    }

    /// Reads the agents again; only the newest read lands.
    public func refresh() {
        guard let source else { return }
        read?.cancel()
        // task-owner: one read of `cmux setup mcp`; the next read or stop() cancels it.
        read = Task { [weak self] in
            let found = await source.agentToolsAgents()
            guard let self, !Task.isCancelled else { return }
            agents = found
            loaded = true
        }
    }

    /// Turn On: the answer is yes; the agents are read again to show it.
    public func add() {
        guard !applying else { return }
        answered = true
        apply(choice: .on)
    }

    /// Not Now: the answer is no. Nothing else changes.
    public func decline() {
        guard !applying else { return }
        answered = true
        apply(choice: .off)
    }

    /// Sets the answer without running anything (Settings' choice row).
    public func setChoice(_ next: AgentToolsChoice) {
        localChoice = next
        guard let source else { return }
        // task-owner: one settings write the person asked for.
        Task { _ = await source.setAgentToolsChoice(next) }
    }

    private func apply(choice next: AgentToolsChoice) {
        localChoice = next
        guard let source else {
            failed = true
            return
        }
        applying = true
        failed = false
        run?.cancel()
        read?.cancel()
        // task-owner: one settings write the person asked for, then (a yes) one read of the agents.
        run = Task { [weak self] in
            let written = await source.setAgentToolsChoice(next)
            // A yes reads the agents again, to show them getting cmux's tools; a no changes none.
            let found = written && next == .on ? await source.agentToolsAgents() : nil
            guard let self, !Task.isCancelled else { return }
            applying = false
            loaded = true
            if let found { agents = found }
            failed = !written
        }
    }

    /// The agents that get cmux's tools when cmux starts them.
    public var addedCount: Int { agents.filter(\.state.givesTools).count }

    /// The window closed: reads stop. A run the person started finishes (it writes their answer).
    public func stop() {
        read?.cancel()
    }
}

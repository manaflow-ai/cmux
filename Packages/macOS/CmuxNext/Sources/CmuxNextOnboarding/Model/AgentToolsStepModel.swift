public import CmuxNextAgentIntegrations
import Foundation
public import Observation

/// The cmux Tools step (and Settings > Agents' row): asks whether cmux may add its MCP server,
/// Computer Use included, to the person's coding agents, lists the agents found, and keeps the
/// answer. Add to My Agents sets `on` and runs `cmux setup mcp` for the agents found; Not Now sets
/// `off` and writes nothing. Nothing runs until the person answers (Aziz, 2026-11-10: "prevent
/// overstepping on a user's setup").
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
        // task-owner: one read of `cmux setup mcp --dry-run`; the next read or stop() cancels it.
        read = Task { [weak self] in
            let found = await source.agentToolsAgents()
            guard let self, !Task.isCancelled else { return }
            agents = found
            loaded = true
        }
    }

    /// Add to My Agents: the answer is yes, then cmux's server goes into each agent found.
    public func add() {
        guard !applying else { return }
        answered = true
        apply(choice: .on, remove: false)
    }

    /// Not Now: the answer is no; nothing is written to any agent.
    public func decline() {
        guard !applying else { return }
        answered = true
        localChoice = .off
        failed = false
        guard let source else { return }
        run?.cancel()
        // task-owner: one settings write the person asked for; a refused write shows as failed.
        run = Task { [weak self] in
            let written = await source.setAgentToolsChoice(.off)
            self?.failed = !written
        }
    }

    /// Settings' Remove from My Agents: cmux's own entries come out of the agents' configs; the
    /// answer stays as it is (Remove alone writes no answer).
    public func remove() {
        guard !applying else { return }
        apply(choice: nil, remove: true)
    }

    /// Sets the answer without running anything (Settings' choice row).
    public func setChoice(_ next: AgentToolsChoice) {
        localChoice = next
        guard let source else { return }
        // task-owner: one settings write the person asked for.
        Task { _ = await source.setAgentToolsChoice(next) }
    }

    private func apply(choice next: AgentToolsChoice?, remove: Bool) {
        if let next { localChoice = next }
        guard let source else {
            failed = true
            return
        }
        applying = true
        failed = false
        run?.cancel()
        read?.cancel()
        // task-owner: one run the person asked for: the answer reaches the settings file first,
        // since `cmux setup mcp` reads it; then the CLI writes the agents' configs.
        run = Task { [weak self] in
            // A refused answer stops here: `cmux setup mcp` would not see it and would write nothing.
            if let next, !(await source.setAgentToolsChoice(next)) {
                guard let self else { return }
                applying = false
                failed = true
                return
            }
            let result = await source.applyAgentTools(remove: remove)
            guard let self, !Task.isCancelled else { return }
            applying = false
            loaded = true
            if let result { agents = result }
            // An Add that left an agent without cmux's server (refused by the CLI, a server of the
            // person's named cmux, a config it could not read) did not do what the person asked.
            failed = result == nil || result?.contains { $0.state == .failed || (!remove && $0.state != .added) } == true
        }
    }

    /// The agents that have cmux's tools after the run.
    public var addedCount: Int { agents.filter { $0.state == .added }.count }

    /// The window closed: reads stop. A run the person started finishes (it writes their configs
    /// and is short), so a closed window never leaves a config half written.
    public func stop() {
        read?.cancel()
    }
}

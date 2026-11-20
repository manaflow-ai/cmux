import CmuxNextDaemon
public import CmuxNextSettings
public import Foundation
import os

/// The cmux Tools question's source over the bundled CLI: the answer is `agents.cmuxMcp`, read from
/// and written through the app's settings owner (the person's own write; `ask` removes the key); the
/// agents are `cmux setup mcp`'s report (the code a person or an agent runs in a terminal), which
/// writes nothing. The CLI runs off the main thread with the login `PATH` a terminal has, so it
/// finds the `claude` and `codex` a terminal finds.
@MainActor
public final class AgentToolsCLISource: AgentToolsSource {
    private let cli: @MainActor () async -> URL?
    private let settings: @MainActor () -> SettingsController?

    /// `settings` is the app's settings owner (nil before it started).
    public init(cli: @escaping @MainActor () async -> URL?, settings: @escaping @MainActor () -> SettingsController?) {
        self.cli = cli
        self.settings = settings
    }

    /// Read inside observation, so a view of it follows an answer given anywhere.
    public func agentToolsChoice() -> AgentToolsChoice {
        settings()?.snapshot.root.value(at: AgentToolsChoice.path)?.stringValue.flatMap(AgentToolsChoice.init(rawValue:)) ?? .ask
    }

    public func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool {
        guard let settings = settings() else { return false }
        do {
            try await settings.setSetting(at: AgentToolsChoice.path, to: .string(choice.rawValue), by: .user)
            return true
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "onboarding")
                .error("agents.cmuxMcp write refused: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func agentToolsAgents() async -> [AgentToolsAgent] {
        await agentToolsReport()?.agents ?? []
    }

    public func agentToolsReport() async -> AgentToolsReport? {
        guard let cli = await cli(), let report = await Self.setupMCP(cli, []),
              let agents = AgentToolsAgent.agents(setupReport: report) else { return nil }
        return AgentToolsReport(agents: agents, manual: AgentToolsAgent.manualCommands(setupReport: report))
    }

    public func removeLeftoverEntry(_ id: String) async -> AgentToolsRemoval {
        guard ["claude", "codex"].contains(id), let cli = await cli(),
              let data = await Self.setupMCP(cli, ["--remove", id, "--confirm"]) else { return .failed }
        return AgentToolsRemoval(removeReport: data)
    }

    /// `cmux --json setup mcp <arguments>` off the main thread; its stdout (a failed run prints its
    /// report there too), or nil when it did not run.
    @concurrent nonisolated static func setupMCP(_ cli: URL, _ arguments: [String]) async -> Data? {
        var environment = ProcessInfo.processInfo.environment
        if let path = LoginEnvironment.shared.rememberedPath() { environment["PATH"] = path }
        let result = try? await ProcessRunner.run(executable: cli, arguments: ["--json", "setup", "mcp"] + arguments,
                                                  environment: environment, timeout: .seconds(90), clock: ContinuousClock())
        return result?.stdout
    }
}

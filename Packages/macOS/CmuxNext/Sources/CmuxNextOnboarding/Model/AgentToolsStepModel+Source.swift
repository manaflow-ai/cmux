public import CmuxNextAgentIntegrations
public import CmuxNextSettings
public import Foundation

public extension AgentToolsStepModel {
    /// The app's source of the cmux Tools answer and agents: the bundled CLI's `cmux setup mcp` and the
    /// settings owner (``AgentToolsCLISource``), for the step, the Set Up cmux card and Settings.
    @MainActor
    static func cliSource(cli: @escaping @MainActor () async -> URL?,
                          settings: @escaping @MainActor () -> SettingsController?) -> AgentToolsCLISource {
        AgentToolsCLISource(cli: cli, settings: settings)
    }
}

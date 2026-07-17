import Foundation

/// Builds the shell input used to start a supported agent from Dispatch.
struct DispatchAgentCommandBuilder {
    static let promptByteBudget = 900

    enum CommandError: Error, Equatable {
        case unsupportedAgent
        case emptyPrompt
        case promptTooLong
    }

    func command(agent: AgentSessionProviderID, prompt: String) throws -> String {
        guard agent == .claude || agent == .codex else {
            throw CommandError.unsupportedAgent
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.emptyPrompt
        }
        guard prompt.utf8.count <= Self.promptByteBudget else {
            throw CommandError.promptTooLong
        }
        return "\(agent.executableName) \(TerminalStartupShellQuoting.singleQuoted(prompt))\n"
    }
}

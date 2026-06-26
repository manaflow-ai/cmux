import Foundation

/// The action a surface tab-bar button performs when activated: a built-in
/// action, a literal terminal command, an agent launch, a named workspace
/// command, or a reference to another configured action by identifier.
public enum CmuxSurfaceTabBarButtonAction: Sendable, Hashable {
    /// A built-in cmux action (new terminal, split, etc.).
    case builtIn(CmuxSurfaceTabBarBuiltInAction)
    /// A literal terminal command string to run.
    case command(String)
    /// Launch a coding agent, with optional extra command-line arguments.
    case agent(CmuxConfigAgentKind, args: String?)
    /// Invoke a named workspace command defined elsewhere in config.
    case workspaceCommand(String)
    /// Reference another configured action by its identifier.
    case actionReference(String)

    /// The default identifier for this action, used when none is set
    /// explicitly. Command and workspace-command actions derive a stable,
    /// percent-encoded identifier from their string.
    public var defaultId: String {
        switch self {
        case .builtIn(let action):
            return action.configID
        case .command(let command):
            return "command." + Self.generatedCommandId(for: command)
        case .agent(let agent, _):
            return agent.commandName
        case .workspaceCommand(let commandName):
            return "workspaceCommand." + Self.generatedCommandId(for: commandName)
        case .actionReference(let identifier):
            return identifier
        }
    }

    /// The default SF Symbol name for this action's tab-bar button.
    public var defaultIcon: String {
        defaultButtonIcon.symbolName
    }

    /// The default button icon for this action.
    public var defaultButtonIcon: CmuxButtonIcon {
        switch self {
        case .builtIn(let action):
            return .symbol(action.defaultIcon)
        case .command:
            return .symbol("terminal")
        case .agent(let agent, _):
            return agent.defaultIcon
        case .workspaceCommand:
            return .symbol("rectangle.stack.badge.plus")
        case .actionReference:
            return .symbol("questionmark.circle")
        }
    }

    /// The terminal command this action runs, or `nil` for actions that do not
    /// run a command. Agent actions combine the agent command name with any
    /// trimmed extra arguments.
    public var terminalCommand: String? {
        switch self {
        case .command(let command):
            return command
        case .agent(let agent, let args):
            let trimmedArgs = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedArgs.isEmpty ? agent.commandName : "\(agent.commandName) \(trimmedArgs)"
        case .builtIn, .workspaceCommand, .actionReference:
            return nil
        }
    }

    /// The workspace command name for a `.workspaceCommand` action, otherwise
    /// `nil`.
    public var workspaceCommandName: String? {
        if case .workspaceCommand(let name) = self {
            return name
        }
        return nil
    }

    /// Percent-encodes a command string into a stable identifier component,
    /// allowing alphanumerics plus `._-` and falling back to `"command"` when
    /// the result is empty.
    private static func generatedCommandId(for command: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? command
        return encoded.isEmpty ? "command" : encoded
    }
}

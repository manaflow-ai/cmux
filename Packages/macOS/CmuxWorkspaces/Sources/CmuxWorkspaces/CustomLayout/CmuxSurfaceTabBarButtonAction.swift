public import Foundation

/// The action a cmux tab-bar / action button performs, in the `cmux.json` wire
/// schema.
///
/// Every other action value type (the button definition, plus-button and
/// right-click menu entries) builds on this base enum. The five cases cover a
/// built-in action (``CmuxSurfaceTabBarBuiltInAction``), a raw terminal
/// ``command``, an ``agent`` launch with optional arguments, a named
/// ``workspaceCommand``, and an ``actionReference`` to a user-defined action by
/// identifier. ``defaultId`` derives the stable identifier each case advertises
/// (built-ins use their config id, commands and workspace commands use a
/// percent-encoded id under a `command.` / `workspaceCommand.` prefix, agents
/// use the agent command name, and an action reference is its own identifier).
/// ``defaultButtonIcon`` / ``defaultIcon`` give the icon shown when a button
/// does not override it, ``terminalCommand`` is the shell command for the
/// command / agent cases (agents append trimmed args), and
/// ``workspaceCommandName`` unwraps the workspace-command case.
public enum CmuxSurfaceTabBarButtonAction: Sendable, Hashable {
    /// A cmux built-in action identified by its `cmux.*` config id.
    case builtIn(CmuxSurfaceTabBarBuiltInAction)
    /// A raw terminal command to run.
    case command(String)
    /// Launch a coding agent with optional trailing arguments.
    case agent(CmuxConfigAgentKind, args: String?)
    /// Run a named workspace command.
    case workspaceCommand(String)
    /// Reference a user-defined action by its identifier.
    case actionReference(String)

    /// The stable identifier this action advertises by default.
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

    /// The SF Symbol name of ``defaultButtonIcon``.
    public var defaultIcon: String {
        defaultButtonIcon.symbolName
    }

    /// The icon shown when a button does not override its icon.
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

    /// The shell command for the ``command`` / ``agent`` cases (agents append
    /// trimmed args), or `nil` for the other cases.
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

    /// The command name for the ``workspaceCommand`` case, or `nil` otherwise.
    public var workspaceCommandName: String? {
        if case .workspaceCommand(let name) = self {
            return name
        }
        return nil
    }

    private static func generatedCommandId(for command: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? command
        return encoded.isEmpty ? "command" : encoded
    }
}

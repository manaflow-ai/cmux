/// A diagnostic surfaced while resolving the `cmux.json` configuration
/// hierarchy: an unresolved `newWorkspace` action/command reference, a workspace
/// command used where one is required, or a schema validation error.
///
/// Produced by the per-window config-resolution path and consumed by the
/// command palette to list configuration problems. The value carries the
/// originating setting name, the optional referenced command name, the source
/// config file path, and an optional schema message; `logMessage` renders the
/// human-readable diagnostic and `id` derives a stable identity from all
/// fields so SwiftUI can diff the issue list.
public struct CmuxConfigIssue: Identifiable, Equatable, Sendable {
    /// The category of configuration problem.
    public enum Kind: String, Sendable {
        /// A `newWorkspace` action reference did not match any loaded action.
        case newWorkspaceActionNotFound
        /// A `newWorkspace` command reference did not match any loaded command.
        case newWorkspaceCommandNotFound
        /// A `newWorkspace` reference pointed at a non-workspace command.
        case newWorkspaceCommandRequiresWorkspace
        /// A schema validation error occurred while parsing the setting.
        case schemaError
    }

    /// The category of configuration problem.
    public let kind: Kind
    /// The name of the setting that produced the issue.
    public let settingName: String
    /// The referenced command/action name, when the issue concerns a reference.
    public let commandName: String?
    /// The config file path the issue originated from, when known.
    public let sourcePath: String?
    /// A schema error message, when `kind` is `.schemaError`.
    public let message: String?

    /// Creates a configuration issue.
    public init(
        kind: Kind,
        settingName: String,
        commandName: String? = nil,
        sourcePath: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.settingName = settingName
        self.commandName = commandName
        self.sourcePath = sourcePath
        self.message = message
    }

    /// A stable identity derived from every field, joined by `|`.
    public var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    /// A human-readable diagnostic message for logging and display.
    public var logMessage: String {
        switch kind {
        case .newWorkspaceActionNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded action"
        case .newWorkspaceCommandNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded command"
        case .newWorkspaceCommandRequiresWorkspace:
            return "\(settingName) '\(commandName ?? "")' must reference a workspace command"
        case .schemaError:
            return "\(settingName) has a schema error: \(message ?? "unknown error")"
        }
    }
}

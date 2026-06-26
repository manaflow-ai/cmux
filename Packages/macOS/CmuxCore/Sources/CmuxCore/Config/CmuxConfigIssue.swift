/// A validation problem discovered while loading `cmux.json` configuration.
///
/// Pure value type: it carries the issue's category, the originating setting and
/// command names, the source file path, and an optional schema message. The
/// command palette and the config loader both surface these; the loader logs
/// ``logMessage`` and the palette renders localized titles/details from the
/// stored fields.
public struct CmuxConfigIssue: Identifiable, Equatable, Sendable {
    /// The category of configuration problem.
    public enum Kind: String, Sendable {
        /// A `newWorkspace` action reference did not match any loaded action.
        case newWorkspaceActionNotFound
        /// A `newWorkspace` command reference did not match any loaded command.
        case newWorkspaceCommandNotFound
        /// A `newWorkspace` command reference pointed at a non-workspace command.
        case newWorkspaceCommandRequiresWorkspace
        /// The configuration failed schema validation.
        case schemaError
    }

    /// The category of this issue.
    public let kind: Kind
    /// The setting name the issue originated from.
    public let settingName: String
    /// The referenced command/action name, when applicable.
    public let commandName: String?
    /// The source configuration file path, when known.
    public let sourcePath: String?
    /// A schema-error message, when applicable.
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

    /// A stable identity composed of the issue's fields, used for deduplication
    /// and command-palette command IDs.
    public var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    /// A human-readable, non-localized message logged when the issue is detected.
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

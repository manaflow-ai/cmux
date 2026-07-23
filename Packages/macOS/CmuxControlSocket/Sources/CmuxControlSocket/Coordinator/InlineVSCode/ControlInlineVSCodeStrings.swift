/// App-bundle-resolved messages used by the inline VS Code socket domain.
///
/// The package must not resolve these keys itself because its bundle does not
/// contain the app's localization catalog.
public struct ControlInlineVSCodeStrings: Sendable, Equatable {
    /// The request omitted its directory path.
    public let missingPath: String
    /// The requested path does not exist.
    public let directoryNotFound: String
    /// The requested path exists but is not a directory.
    public let notDirectory: String
    /// No routed app window can host the inline editor.
    public let tabManagerUnavailable: String
    /// The explicit workspace or pane target could not be resolved.
    public let workspaceNotFound: String
    /// A compatible VS Code installation is unavailable.
    public let vscodeUnavailable: String
    /// The inline editor request could not be queued.
    public let openFailed: String

    /// Creates the app-resolved inline VS Code message set.
    public init(
        missingPath: String,
        directoryNotFound: String,
        notDirectory: String,
        tabManagerUnavailable: String,
        workspaceNotFound: String,
        vscodeUnavailable: String,
        openFailed: String
    ) {
        self.missingPath = missingPath
        self.directoryNotFound = directoryNotFound
        self.notDirectory = notDirectory
        self.tabManagerUnavailable = tabManagerUnavailable
        self.workspaceNotFound = workspaceNotFound
        self.vscodeUnavailable = vscodeUnavailable
        self.openFailed = openFailed
    }
}

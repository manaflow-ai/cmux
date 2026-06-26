/// Localized error messages surfaced to AppleScript clients when a scripting
/// command cannot complete.
///
/// This is the injected strings payload for the AppleScript scripting seam: a
/// pure `Sendable` value type carrying the resolved, human-readable message for
/// every failure the scripting bridge can report (`scriptErrorString`). The
/// app constructs an instance with `String(localized:)`-resolved values from
/// the app bundle and hands it to the scripting command bodies, so localization
/// stays app-resolved while the value-type shape lives in the package.
public struct AppleScriptErrorStrings: Sendable {
    /// AppleScript automation is disabled by configuration.
    public let disabled: String
    /// A required action string was not supplied.
    public let missingAction: String
    /// A required input text string was not supplied.
    public let missingInputText: String
    /// A required terminal target was not supplied.
    public let missingTerminalTarget: String
    /// The split direction was missing or unrecognized.
    public let missingSplitDirection: String
    /// The referenced window no longer exists.
    public let windowUnavailable: String
    /// The referenced workspace (tab) no longer exists.
    public let workspaceUnavailable: String
    /// The referenced terminal no longer exists.
    public let terminalUnavailable: String
    /// Creating a new window failed.
    public let failedToCreateWindow: String
    /// Creating a new workspace (tab) failed.
    public let failedToCreateWorkspace: String
    /// Creating a new split failed.
    public let failedToCreateSplit: String

    /// Creates the payload from already-resolved, localized message strings.
    public init(
        disabled: String,
        missingAction: String,
        missingInputText: String,
        missingTerminalTarget: String,
        missingSplitDirection: String,
        windowUnavailable: String,
        workspaceUnavailable: String,
        terminalUnavailable: String,
        failedToCreateWindow: String,
        failedToCreateWorkspace: String,
        failedToCreateSplit: String
    ) {
        self.disabled = disabled
        self.missingAction = missingAction
        self.missingInputText = missingInputText
        self.missingTerminalTarget = missingTerminalTarget
        self.missingSplitDirection = missingSplitDirection
        self.windowUnavailable = windowUnavailable
        self.workspaceUnavailable = workspaceUnavailable
        self.terminalUnavailable = terminalUnavailable
        self.failedToCreateWindow = failedToCreateWindow
        self.failedToCreateWorkspace = failedToCreateWorkspace
        self.failedToCreateSplit = failedToCreateSplit
    }
}

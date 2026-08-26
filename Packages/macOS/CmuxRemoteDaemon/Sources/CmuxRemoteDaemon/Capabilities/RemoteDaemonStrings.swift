/// User-facing daemon error strings, resolved against the app bundle's
/// localization tables by the app target and passed through this seam so the
/// package never localizes (package-side `String(localized:)` would bind to
/// the wrong bundle and drop translations).
public struct RemoteDaemonStrings: Sendable, Equatable {
    /// `remoteDaemon.error.missingPersistentPTYCapability` —
    /// "remote daemon does not support persistent SSH PTY sessions; reconnect
    /// the remote workspace to update cmux".
    public let missingPersistentPTYCapability: String
    /// `remoteDaemon.error.missingRequiredFunctionality` —
    /// "remote daemon is missing required functionality; reconnect the remote
    /// workspace to update cmux".
    public let missingRequiredFunctionality: String
    /// Invalid workspace selector in a cloud notification clear request.
    public let cloudNotificationClearWorkspaceInvalid: String
    /// Cross-workspace cloud notification clear rejection.
    public let cloudNotificationClearWorkspaceDenied: String
    /// Invalid surface selector in a cloud notification clear request.
    public let cloudNotificationClearSurfaceInvalid: String

    /// Creates the strings bundle from pre-resolved localized strings.
    ///
    /// - Parameters:
    ///   - missingPersistentPTYCapability: Message for missing persistent PTY support.
    ///   - missingRequiredFunctionality: Message for other missing daemon functionality.
    ///   - cloudNotificationClearWorkspaceInvalid: Message for an invalid clear workspace.
    ///   - cloudNotificationClearWorkspaceDenied: Message for a cross-workspace clear.
    ///   - cloudNotificationClearSurfaceInvalid: Message for an invalid clear surface.
    public init(
        missingPersistentPTYCapability: String,
        missingRequiredFunctionality: String,
        cloudNotificationClearWorkspaceInvalid: String,
        cloudNotificationClearWorkspaceDenied: String,
        cloudNotificationClearSurfaceInvalid: String
    ) {
        self.missingPersistentPTYCapability = missingPersistentPTYCapability
        self.missingRequiredFunctionality = missingRequiredFunctionality
        self.cloudNotificationClearWorkspaceInvalid = cloudNotificationClearWorkspaceInvalid
        self.cloudNotificationClearWorkspaceDenied = cloudNotificationClearWorkspaceDenied
        self.cloudNotificationClearSurfaceInvalid = cloudNotificationClearSurfaceInvalid
    }

    /// The message shown when the daemon's `hello` lacks required
    /// capabilities; behavior-identical to the legacy
    /// `remoteDaemonMissingRequiredCapabilitiesMessage` free function.
    public func missingRequiredCapabilitiesMessage(_ missingCapabilities: [String]) -> String {
        let missing = Set(missingCapabilities)
        if !missing.isDisjoint(with: RemoteDaemonCapability.persistentPTYFamily) {
            return missingPersistentPTYCapability
        }
        return missingRequiredFunctionality
    }
}

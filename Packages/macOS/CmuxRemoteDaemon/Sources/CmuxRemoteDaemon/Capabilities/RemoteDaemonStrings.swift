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

    /// Creates the strings bundle from pre-resolved localized strings.
    public init(
        missingPersistentPTYCapability: String,
        missingRequiredFunctionality: String
    ) {
        self.missingPersistentPTYCapability = missingPersistentPTYCapability
        self.missingRequiredFunctionality = missingRequiredFunctionality
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

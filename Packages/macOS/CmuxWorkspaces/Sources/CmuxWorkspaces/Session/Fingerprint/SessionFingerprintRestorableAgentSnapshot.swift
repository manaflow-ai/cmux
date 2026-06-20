/// The restorable-agent fields the session autosave fingerprint folds into its
/// hash, flattened off the app-target `SessionRestorableAgentSnapshot`.
///
/// Carries only the values the legacy
/// `TabManager.hashRestorableAgentSnapshot(_:into:)` combined, in order: the
/// agent `kind`'s string `rawValue` (resolved app-side so the package needs no
/// `RestorableAgentKind`), the session id, the working directory, and the
/// flattened launch command. The app-side ``SessionFingerprintHosting`` witness
/// maps the live snapshot into this value.
public struct SessionFingerprintRestorableAgentSnapshot: Sendable, Equatable {
    /// Legacy `SessionRestorableAgentSnapshot.kind.rawValue`, resolved app-side.
    public let kindRawValue: String
    /// Legacy `SessionRestorableAgentSnapshot.sessionId`.
    public let sessionId: String
    /// Legacy `SessionRestorableAgentSnapshot.workingDirectory`.
    public let workingDirectory: String?
    /// Legacy `SessionRestorableAgentSnapshot.launchCommand`, flattened.
    public let launchCommand: SessionFingerprintAgentLaunchCommandSnapshot?

    /// Creates a flattened restorable-agent fingerprint input.
    public init(
        kindRawValue: String,
        sessionId: String,
        workingDirectory: String?,
        launchCommand: SessionFingerprintAgentLaunchCommandSnapshot?
    ) {
        self.kindRawValue = kindRawValue
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.launchCommand = launchCommand
    }
}

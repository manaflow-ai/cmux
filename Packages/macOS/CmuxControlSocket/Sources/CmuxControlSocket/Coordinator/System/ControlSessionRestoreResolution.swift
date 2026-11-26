/// The outcome of `session.restore_previous` (the legacy
/// `v2SessionRestorePrevious` body).
///
/// The no-snapshot message is resolved in the APP conformance (app bundle) so
/// the `terminal.restore.no_snapshot` localization keeps working; the package
/// only carries the resolved string.
public enum ControlSessionRestoreResolution: Sendable, Equatable {
    /// The previous session snapshot was reopened.
    case restored
    /// No previous session snapshot was available. Carries the app-localized
    /// error message (key `terminal.restore.no_snapshot`).
    case noSnapshot(message: String)
}

/// Presentation of the stored-Mac reconnect episode in the workspace list.
/// The shell owns timing and failure state; this value only maps that state to
/// one spinner, message, and pair of recovery actions.
struct WorkspaceListStoredMacRecoveryPresentation: Equatable {
    let showsSpinner: Bool
    let title: String?
    let description: String?
    let showsRetry: Bool
    let showsAddDevice: Bool

    init(
        isRestoring: Bool,
        recoveryFailed: Bool,
        error: String?,
        guidance: String?
    ) {
        let showsFailure = !isRestoring && recoveryFailed
        showsSpinner = isRestoring
        title = showsFailure ? error : nil
        description = showsFailure ? guidance : nil
        showsRetry = isRestoring || showsFailure
        showsAddDevice = isRestoring || showsFailure
    }
}

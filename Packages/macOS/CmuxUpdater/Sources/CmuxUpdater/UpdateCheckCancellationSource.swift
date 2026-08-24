/// Why cmux ended an in-progress update check.
///
/// Explicit cancellation ends user-owned lifecycle state. Superseding a check is an internal
/// transition and must not be mistaken for the user abandoning an accepted install.
enum UpdateCheckCancellationSource {
    case user
    case superseded
}

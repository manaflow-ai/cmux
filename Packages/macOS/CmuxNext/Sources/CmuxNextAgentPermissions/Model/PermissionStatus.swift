/// What macOS says about one grant now, as a ``PermissionProbe`` reads it
/// (never by prompting).
public nonisolated enum PermissionStatus: String, Sendable, Equatable {
    /// The grant is on.
    case granted
    /// The person turned it off, or macOS refused it.
    case denied
    /// macOS has not asked yet.
    case notDetermined = "not_determined"
    /// The grant cannot be read now (for example, the helper is not running).
    case unknown
}

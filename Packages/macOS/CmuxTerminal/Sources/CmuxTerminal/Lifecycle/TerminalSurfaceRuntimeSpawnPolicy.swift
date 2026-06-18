/// How a terminal surface should enter its native Ghostty runtime.
public enum TerminalSurfaceRuntimeSpawnPolicy: Sendable {
    /// Create the native runtime surface as soon as the view is ready.
    case immediate

    /// Pace creation through the session-restore queue to avoid a login-shell stampede.
    case pacedSessionRestore
}

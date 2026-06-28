/// The two sidebar-log severities the remote-status update coordinator emits.
///
/// The coordinator (in this package) cannot name the app-target `SidebarLogLevel`
/// it ultimately logs at, so it speaks this small `Sendable` enum and the live
/// host maps each case onto the real sidebar level when forwarding to the
/// sidebar metadata model. Only `.warning` (suspended reconnect, port conflicts)
/// and `.error` (SSH/proxy/daemon failures) appear in the lifted bodies, so this
/// is deliberately not a full mirror of the sidebar's level set.
public enum RemoteStatusLogLevel: Sendable {
    /// A recoverable remote condition (reconnect paused, port forwarding conflict).
    case warning
    /// A hard remote failure (SSH error, proxy unavailable, daemon error).
    case error
}

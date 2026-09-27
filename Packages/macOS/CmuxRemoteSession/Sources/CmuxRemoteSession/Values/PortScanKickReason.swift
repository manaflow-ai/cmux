/// Why a remote port scan was requested, controlling how aggressively the
/// scan burst samples the remote host.
///
/// Lifted from the legacy `WorkspaceRemoteSessionController.PortScanKickReason`
/// nested enum; the raw values and burst offsets are pinned behavior (socket
/// commands parse the raw strings, and the offsets shape observable scan
/// traffic).
public enum PortScanKickReason: String, Sendable {
    /// A command just ran (or a foreground process started): scan in an
    /// escalating burst so newly bound ports appear quickly.
    case command
    /// A passive refresh (prompt return, idle poll): a single immediate scan.
    case refresh

    /// Seconds from the burst start at which each scan pass fires.
    var burstOffsets: [Double] {
        switch self {
        case .command:
            return [0.5, 1.5, 3.0, 5.0, 7.5, 10.0]
        case .refresh:
            return [0.0]
        }
    }

    /// Combines two pending reasons; `.command` (the more aggressive burst)
    /// wins.
    func merged(with other: Self) -> Self {
        switch (self, other) {
        case (.command, _), (_, .command):
            return .command
        case (.refresh, .refresh):
            return .refresh
        }
    }
}

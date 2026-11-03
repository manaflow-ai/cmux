public import CmuxNextDaemon

/// One answer to "why is this machine's daemon not connected" for every
/// surface that would otherwise say only "not connected" (the App Store and
/// app sections, command failures): the real cause, never a bare state
/// (cx-4bd8m: after an update the owner spent minutes restoring and every
/// page read "cmux-tui is not connected" with no reason).
extension DaemonService {
    /// Nil while connected. Else, in order: the last failed connect attempt
    /// (still restoring, the launch or handshake error), the drop's reason,
    /// or that the service is still starting.
    public var notConnectedReason: String? {
        // The owner is alive and restoring: name its job, never a failure.
        if startup.isRestoring, connection == nil { return RefusalStrings.restoring(startup.restoringJobs) }
        switch store.connectionState {
        case .connected: nil
        case .connecting: lastStartupError.map { RefusalStrings.describe($0) } ?? RefusalStrings.daemonConnecting
        case .disconnected(let why), .failed(let why): lastStartupError.map { RefusalStrings.describe($0) } ?? why
        }
    }
}

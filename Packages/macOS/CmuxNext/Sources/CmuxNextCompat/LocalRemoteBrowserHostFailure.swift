public import Foundation

/// Why a loopback remote browser host (CmuxNextRemote's `LocalRemoteBrowserHost`) did not start.
/// A value here, in core, so the remote tab's strings (CmuxNextRemoteBrowser, a UI target) say it
/// without depending on the service that starts the host.
public nonisolated enum LocalRemoteBrowserHostFailure: Error, Equatable {
    /// The executable could not be launched.
    case launch(String)
    /// The host exited (or closed stdout) before it listened; `log` is
    /// its stderr log.
    case exitedBeforeListening(log: URL)
    /// The host did not listen within `seconds`; it was stopped.
    case timedOut(seconds: Int, log: URL)
}

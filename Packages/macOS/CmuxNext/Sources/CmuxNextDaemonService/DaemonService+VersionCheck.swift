public import CmuxNextDaemon

extension DaemonService {
    /// The launch-time version check of the local owner `identity` against the bundled build
    /// (`cmux --version --json`, nil when the bundled binary did not answer): `.restart` when the
    /// app should hand the owner off (``DaemonLauncher/handOffIfStale(identity:using:bundled:)``
    /// then decides again and sends it), else `.keep` with the reason, which the app logs.
    nonisolated static func launchVersionCheck(identity: DaemonIdentity, bundled: DaemonBuildStamp?) -> DaemonVersionDecision {
        guard let bundled else { return .keep("bundled build unknown") }
        return DaemonLauncher.versionDecision(running: DaemonBuildStamp(identity: identity), bundled: bundled)
    }
}

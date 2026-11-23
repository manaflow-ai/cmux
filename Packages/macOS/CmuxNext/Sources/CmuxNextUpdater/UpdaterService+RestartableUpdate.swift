extension UpdaterService {
    /// The downloaded update that Restart to Update installs now, or nil while none waits: an
    /// update still checking or downloading, an install under way, or a staged build known
    /// pulled (``stagedPulledHeld``, which no card offers either) is not one. With none staged, a
    /// newer build already installed on disk (``installedBuild``) is one: Restart to Update opens it.
    public var restartableUpdate: RestartableUpdate? {
        guard case .ready(let version) = flow.phase, !stagedPulledHeld else {
            // A newer build already installed on disk: the same button, which relaunches.
            return relaunchInstalledBuild == nil ? nil : installedNewerBuild.map { RestartableUpdate(version: $0.displayVersion) }
        }
        return RestartableUpdate(version: stagedVersion ?? version)
    }
}

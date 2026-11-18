extension UpdaterService {
    /// The downloaded update that Restart to Update installs now, or nil while none waits: an
    /// update still checking or downloading, an install under way, or a staged build known
    /// pulled (``stagedPulledHeld``, which no card offers either) is not one.
    public var restartableUpdate: RestartableUpdate? {
        guard case .ready(let version) = flow.phase, !stagedPulledHeld else { return nil }
        return RestartableUpdate(version: stagedVersion ?? version)
    }
}

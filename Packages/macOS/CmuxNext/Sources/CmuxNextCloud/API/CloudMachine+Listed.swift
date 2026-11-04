extension CloudMachine {
    /// This list read's record taken over `current`, the session's copy (`CloudMachineSession.listed`).
    /// A connect since the read began (`connectedSinceRead`: a click's, which starts a paused machine)
    /// is newer than the answer, so a record that is not live keeps `current`'s live status, pause
    /// reason and running start, and takes the record's other fields.
    public func listed(over current: CloudMachine, connectedSinceRead: Bool) -> CloudMachine {
        var accepted = self
        if current.status.isLive, !status.isLive, connectedSinceRead {
            (accepted.status, accepted.pauseReason, accepted.runningSince) = (current.status, current.pauseReason, current.runningSince)
        }
        return accepted
    }
}

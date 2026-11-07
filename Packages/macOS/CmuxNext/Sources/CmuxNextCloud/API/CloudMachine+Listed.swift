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

    /// What a session does when this record replaces one whose status was `previous` (`CloudMachineSession.applyRecord`):
    /// suspend its link, connect it, or retry a machine whose daemon answers only now.
    public enum RecordEdge: Equatable, Sendable { case suspend, connect, retry }

    /// This record's ``RecordEdge`` over `previous`; `wasResuming`: that one showed a pending resume; `connected`: the
    /// session's daemon has a connection. Nil: nothing to do.
    public func edge(from previous: Status, wasResuming: Bool, connected: Bool) -> RecordEdge? {
        if previous.isLive, !status.isLive { return .suspend }
        if !previous.isLive, status.isLive { return .connect }
        // A read can report running while the resume still awaits acknowledgement: clearing its overlay is a second live edge.
        if wasResuming, pendingChange == nil, status.isLive, !connected { return .connect }
        // A new machine is live while it provisions, but its daemon answers only once it runs.
        if previous == .starting || previous == .provisioning, status == .running, !connected { return .retry }
        return nil
    }

    /// Whether a pending change holds back a connect from `origin` (`CloudMachineSession.connect`): a person's app-link
    /// connect runs through `starting`, which a passive typing wake reads too (cmux#34974); a pause, a delete and every
    /// legacy link keep the strict hold.
    public func holdsConnect(origin: CloudLinkOrigin, appLink: Bool) -> Bool {
        shownStatus.isChanging && !(origin == .user && appLink && shownStatus == .starting)
    }
}

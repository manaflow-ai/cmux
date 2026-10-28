import CmuxMemoryPressure

/// Adapts the app-owned process census to the runaway-session selector.
extension CmuxTopProcessSnapshot {
    /// The census for runaway-session selection, or nil when the capture is
    /// unavailable or incomplete, so a reused group ID can't be ruled out.
    func runawaySessionCensus() -> RunawaySessionCensus? {
        guard captureIsAvailable, enumerationIsComplete else { return nil }
        return RunawaySessionCensus(
            processes: processesByPID.values.map { process in
                RunawaySessionProcess(
                    pid: process.pid,
                    parentPID: process.parentPID,
                    name: process.name,
                    processGroupID: process.processGroupID,
                    ttyDevice: process.ttyDevice,
                    memoryBytes: process.memoryBytes,
                    startMicroseconds: process.processIdentity.map {
                        $0.startSeconds &* 1_000_000 &+ $0.startMicroseconds
                    },
                    memoryIsAvailable: includesResources && process.memorySource != .unavailable
                )
            }
        )
    }
}

import CmuxNextCompat
public import Foundation

extension ChiefHome {
    /// Whether this home's Chief is on, the liveness the default Chief's Auto choice reads
    /// (`HomeChiefDefault`): its brain host holds the home's lock, or no host holds it only for a
    /// moment between two hosts this app starts (an update's handoff, a restart after a crash).
    ///
    /// An update stops the host between turns and the next one starts some seconds later
    /// (Lawrence 2026-11-23: "when i update cmux it focuses cloud chief instead of normal chief";
    /// the relaunched app read the lock in that gap). The Chief is off only when it was shut down
    /// on purpose (`cmux chief shutdown`'s ``shutdownMarker``), when this app cannot start a host,
    /// or when the brain keeper stopped restarting one that kept dying.
    ///
    /// Reads the lock and stats the marker: call it off the main actor.
    /// - Parameters:
    ///   - canStart: this app can start a host (``HomeBrainHost/canStart(environment:bundledBinDirectory:bundledChiefAllowed:)``).
    ///   - gaveUp: the brain keeper stopped restarting the host (``ChiefBrainKeeper/hasGivenUp``).
    ///   - isChiefHost: whether a pid runs an `optchat-chief`; the tests name a stand-in.
    /// - Returns: true while this home's Chief runs or is between two hosts.
    public nonisolated func isOn(canStart: Bool, gaveUp: Bool,
                                 isChiefHost: (pid_t) -> Bool = ChiefHostStop.isChiefHost) -> Bool {
        if ChiefHostStop.runningHostPID(home: self, isChiefHost: isChiefHost) != nil { return true }
        // One small stat, off the main actor (HomeService.localChiefRuns).
        let shutDown = FileManager.checked.fileExists(atPath: shutdownMarker.path)
        return canStart && !gaveUp && !shutDown
    }
}

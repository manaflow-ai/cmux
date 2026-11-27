/// How long a Mac's link has been down *as the person saw it*: the one clock every outage bound
/// reads (a terminal's "offline", which refuses its composer's Send, the "Not responding" stall,
/// the header's "Offline").
///
/// Time iOS kept the app away is not outage anyone waited through. Back in front
/// (``foregrounded(at:)``) an outage still open starts again at that instant, so the bounds count
/// from the return. Before, a link that dropped while the app was away came back already 5 minutes
/// "down": the first foreground read put every terminal offline at once, refused Send and said
/// "Mac offline" during the reattach. Leo, 2026-11-24: "The like multi-second long reattach where
/// like the entire thing is somehow grayed out and I can't interact with anything at all."
struct LinkOutageClock: Equatable, Sendable {
    /// When the link last stopped being connected, or when the app came back while it was down
    /// (nil: connected or idle).
    private(set) var since: ContinuousClock.Instant?

    /// Follows the link's phase at `now`; returns how long it has been down.
    mutating func follow(_ phase: LinkMachine.Phase, at now: ContinuousClock.Instant) -> Duration {
        if phase.isConnected || phase == .idle {
            since = nil
        } else if since == nil {
            since = now
        }
        return since.map { now - $0 } ?? .zero
    }

    /// The app is in front again at `now`: an open outage counts from here.
    mutating func foregrounded(at now: ContinuousClock.Instant) {
        if since != nil { since = now }
    }

    /// Whether a Mac's terminal tabs say it is offline: a closed (idle) link of a started team at
    /// once, otherwise the phase's own bound (``LinkMachine/Phase/showsTerminalsOffline(notConnectedFor:)``)
    /// on this clock's `down`.
    static func terminalsOffline(_ phase: LinkMachine.Phase, down: Duration, teamStarted: Bool) -> Bool {
        (phase == .idle && teamStarted) || phase.showsTerminalsOffline(notConnectedFor: down)
    }
}

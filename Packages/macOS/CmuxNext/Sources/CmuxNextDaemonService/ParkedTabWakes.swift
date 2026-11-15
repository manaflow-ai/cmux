import CmuxNextCompat
public import CmuxNextDaemon

/// The parked tabs whose `restart-tab` is in flight (`DaemonService.wakeParkedTabs`), observed one
/// surface at a time: the view of a tab hears its own tab start and end its wake, and no other.
public final class ParkedTabWakes {
    private let waking = ObservedMap<SurfaceID, Bool>()

    /// Whether the restart of `surface` is in flight; observes `surface` only.
    public func contains(_ surface: SurfaceID) -> Bool { waking[surface] == true }

    /// The end of `tab` as its terminal view names it: the tab's own end, but none while the daemon
    /// tries the tab's failed restart again, so the view does not say that the restart failed. The end
    /// of that try (the tab is still dead, or dead again) brings the end back. Observes the wake of
    /// `tab` only when its end is a failed restart: the view of no other tab makes an entry here.
    public func shownEnd(of tab: TabModel?) -> TerminalTabEnd? {
        guard let tab, let end = tab.end else { return nil }
        return end.reason == .restartFailed && contains(tab.surface) ? nil : end
    }

    func formUnion(_ surfaces: some Sequence<SurfaceID>) {
        for surface in surfaces { waking[surface] = true }
    }

    func remove(_ surface: SurfaceID) { waking[surface] = nil }
}

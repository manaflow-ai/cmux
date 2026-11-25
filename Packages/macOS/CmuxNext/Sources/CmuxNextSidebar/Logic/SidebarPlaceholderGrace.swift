import CmuxNextWakeups

/// The wait before a connecting machine's section shows its placeholder bars
/// (`SidebarSeed`): a machine that connects within `delay` never flashes them.
/// The wait runs on the injected clock, once per loading spell of a section;
/// `onEnd` asks the owner to merge again when one ends.
@MainActor
public final class SidebarPlaceholderGrace {
    public static let delay: Duration = .milliseconds(300)
    /// The wait before one list names "Connecting…": the shared connection quiet time
    /// (``QuietHold/connectionDelay``: the daemon's startup deadline, which the store's drop grace uses too).
    public static let connectingDelay: Duration = QuietHold.connectionDelay

    /// Runs when a section's wait ends (the bridge runs its rows pass again).
    public var onEnd: (@MainActor () -> Void)?
    private let clock: any Clock<Duration>
    /// This grace's wait (`delay` for the placeholder bars).
    private let wait: Duration
    private var ended: Set<SectionID> = []
    private var waits: [SectionID: DemandTimer] = [:]

    public init(wait: Duration = SidebarPlaceholderGrace.delay, clock: any Clock<Duration> = ContinuousClock()) {
        self.wait = wait
        self.clock = clock
    }

    /// This grace, its `onEnd` running `sameTurn`'s passes (the rows pass merges again).
    public func rerunning(_ sameTurn: SidebarSameTurn) -> SidebarPlaceholderGrace {
        onEnd = { [weak sameTurn] in sameTurn?.syncNow(rows: true) }
        return self
    }

    /// Whether `section` may show placeholders now; the first ask starts its wait.
    func allows(_ section: SectionID) -> Bool {
        if ended.contains(section) { return true }
        guard waits[section] == nil else { return false }
        let timer = DemandTimer(owner: "sidebar-placeholder-grace", clock: clock)
        waits[section] = timer
        timer.schedule(after: wait) { @MainActor [weak self] in
            guard let self, waits.removeValue(forKey: section) != nil else { return }
            ended.insert(section)
            onEnd?()
        }
        return false
    }

    /// Forgets the sections not in `listed` (a section that left waits again when it comes back).
    func keep(_ listed: Set<SectionID>) {
        for section in Set(waits.keys).union(ended) where !listed.contains(section) { reset(section) }
    }

    /// `section` stopped loading: a later connect waits again.
    func reset(_ section: SectionID) {
        waits.removeValue(forKey: section)?.cancel()
        ended.remove(section)
    }

    /// `sections` with each machine (This Mac too) whose link has been coming up, dropped or out of reach for
    /// less than this grace's wait marked `holdsStatusLabel`: neither its header (`SectionHeaderRowView`)
    /// nor one list names "Connecting…", "Reconnecting…", "Unreachable" or "Offline" until it lasts
    /// (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up"), since the link
    /// redials on its own and most drops end inside the wait. The wait spans every such state in a
    /// row (reconnecting, then unreachable) and starts again once the link is up. A state a person
    /// must act on (sign-in, install, update) is never held.
    ///
    /// A link coming up or redialing is held for good, however long it lasts: the header keeps its last
    /// look, with no spinner and no "Connecting…" or "Reconnecting…" (Leo, 2026-11-24: "all the
    /// connecting... indicators and the graying out of workspaces, nah let's not do that. let's just keep
    /// optimistically connecting and reinforcing the connection and sync-ups can be satisfying instead of
    /// making the user think they're constsntly suspended in a state of connection limbo"). Only a link
    /// that settled out of reach (unreachable, offline) says so once it lasts the wait.
    public func holdingConnectingLabels(_ sections: [SidebarSection]) -> [SidebarSection] {
        keep(Set(sections.map(\.id)))
        return sections.map { section in
            guard var machine = section.machine else { return section }
            guard Self.healsOnItsOwn(machine.status) else {
                reset(section.id)
                return section
            }
            guard Self.isOnItsWay(machine.status) || !allows(section.id) else { return section }
            machine.holdsStatusLabel = true
            var held = section
            held.kind = .machine(machine)
            return held
        }
    }

    /// A link coming up or redialing: never said, at any age.
    public nonisolated static func isOnItsWay(_ status: SidebarMachine.Status) -> Bool {
        status == .connecting || status == .reconnecting
    }

    /// A link state that ends without anyone acting: coming up, redialing after a drop, or out of
    /// reach until the network answers again.
    nonisolated static func healsOnItsOwn(_ status: SidebarMachine.Status) -> Bool {
        switch status {
        case .connecting, .reconnecting, .unreachable, .offline: true
        case .connected, .updateAvailable, .updateRequired, .installRequired, .installing, .authFailed, .failed,
             .disconnected, .paused, .pausedIdle, .pausing, .resuming, .deleting: false
        }
    }
}

import CmuxNextWakeups

/// The wait before a connecting machine's section shows its placeholder bars
/// (`SidebarSeed`): a machine that connects within `delay` never flashes them.
/// The wait runs on the injected clock, once per loading spell of a section;
/// `onEnd` asks the owner to merge again when one ends.
@MainActor
public final class SidebarPlaceholderGrace {
    public static let delay: Duration = .milliseconds(300)
    /// The startup diagnostic bound kept by callers that also manage placeholder grace: the shared
    /// connection quiet time (``QuietHold/connectionDelay``). Automatic connection labels remain
    /// hidden after this bound.
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

    /// Automatic connection recovery never adds a label or spinner to the cached rows.
    /// A state a person must act on (sign-in, install, update or failure) remains visible.
    public func holdingConnectingLabels(_ sections: [SidebarSection]) -> [SidebarSection] {
        keep(Set(sections.map(\.id)))
        return sections.map { section in
            guard var machine = section.machine else { return section }
            guard Self.healsOnItsOwn(machine.status) else {
                reset(section.id)
                return section
            }
            // No action is available during automatic recovery, even after the grace.
            reset(section.id)
            machine.holdsStatusLabel = true
            var held = section
            held.kind = .machine(machine)
            return held
        }
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

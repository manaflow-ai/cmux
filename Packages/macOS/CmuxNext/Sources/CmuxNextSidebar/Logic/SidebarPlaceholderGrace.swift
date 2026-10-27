import CmuxNextWakeups

/// The wait before a connecting machine's section shows its placeholder bars
/// (`SidebarSeed`): a machine that connects within `delay` never flashes them.
/// The wait runs on the injected clock, once per loading spell of a section;
/// `onEnd` asks the owner to merge again when one ends.
@MainActor
public final class SidebarPlaceholderGrace {
    public static let delay: Duration = .milliseconds(300)

    /// Runs when a section's wait ends (the bridge runs its rows pass again).
    public var onEnd: (@MainActor () -> Void)?
    private let clock: any Clock<Duration>
    private var ended: Set<SectionID> = []
    private var waits: [SectionID: DemandTimer] = [:]

    public init(clock: any Clock<Duration> = ContinuousClock()) {
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
        timer.scheduleOnMain(after: Self.delay) { [weak self] in
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
}

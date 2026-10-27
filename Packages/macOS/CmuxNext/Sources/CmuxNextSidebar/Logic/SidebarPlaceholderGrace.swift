public import CmuxNextWakeups

/// The wait before a connecting machine's section shows its placeholder bars
/// (`SidebarSeed`): a machine that connects within `delay` never flashes them.
/// The wait is one `visible` deadline per loading spell of a section on the app's
/// placer (Chromium's `base::OneShotTimer` on a typed task runner); `onEnd` asks
/// the owner to merge again when one ends.
@MainActor
public final class SidebarPlaceholderGrace {
    public static let delay: Duration = .milliseconds(300)

    /// Runs when a section's wait ends (the bridge runs its rows pass again).
    public var onEnd: (@MainActor () -> Void)?
    private let deadlines: MainDeadlineScheduler
    private var ended: Set<SectionID> = []
    private var waits: [SectionID: MainDeadline] = [:]

    /// - Parameter deadlines: The app's one deadline placer (`AppServices.mainDeadlines`).
    public init(deadlines: MainDeadlineScheduler) {
        self.deadlines = deadlines
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
        let wait = MainDeadline(owner: "Sidebar.placeholderGrace", workClass: .visible, scheduler: deadlines)
        waits[section] = wait
        wait.schedule(after: Self.delay) { [weak self] in
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

public import CmuxNextAgentActivity
import CmuxNextCompat
public import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation

/// The sidebar's Priority view (`sidebar.priorityView.enabled`, an App Store item, off by default):
/// every acpmux chat on this Mac, its peers and the Chief home, and every agent chat on the other
/// machines the app shows, ranked by what needs the person (`AgentPriorityRanking`), at the top of each window's sidebar while the titlebar bell is on
/// (`sidebar.priorityView.shown`). Event-driven: it redraws when a lane, a mark or the setting
/// changes, and at the next snooze end, never on a poll. The App passes the settings, the
/// shortcut, the chat jump and the row actions' runner (its own target keeps them out of
/// CmuxNextApp, code-quality SW14); the chats and their marks are `AgentPriorityChats`.
@MainActor
public final class SidebarPriorityFeed {
    /// `sidebar.priorityView.enabled` and `.shown`, read inside an observation scope.
    public struct Settings {
        public var enabled: @MainActor () -> Bool
        public var shown: @MainActor () -> Bool
        public init(enabled: @escaping @MainActor () -> Bool, shown: @escaping @MainActor () -> Bool) {
            self.enabled = enabled
            self.shown = shown
        }
    }

    /// What the feed asks of the App.
    public struct Hooks {
        /// The Toggle Priority View shortcut for the bell's tooltip.
        public var shortcut: @MainActor () -> String?
        /// Opens the chat.
        public var open: @MainActor (AgentActivityLane) -> Void
        /// Runs the registered action of a row's button (mark read, pin, snooze, archive), the
        /// one its right-click menu and the palette run too.
        public var rowAction: @MainActor (SidebarPriorityAction) -> Void
        /// Runs Toggle Priority View (the bell).
        public var toggleShown: @MainActor () -> Void

        public init(shortcut: @escaping @MainActor () -> String?, open: @escaping @MainActor (AgentActivityLane) -> Void,
                    rowAction: @escaping @MainActor (SidebarPriorityAction) -> Void, toggleShown: @escaping @MainActor () -> Void) {
            self.shortcut = shortcut
            self.open = open
            self.rowAction = rowAction
            self.toggleShown = toggleShown
        }
    }

    private let settings: Settings
    private let hooks: Hooks
    private let chats: AgentPriorityChats
    private var marks: AgentPriorityMarks { chats.marks }
    private let ranking = AgentPriorityRanking()
    /// Bumped when a snooze ends or an idle chat ages out, so the rows redraw with no other change.
    private let clock = PriorityClock()
    private let nextChange = DemandTimer(owner: "sidebar-priority-next-change")

    public init(settings: Settings, hooks: Hooks, chats: AgentPriorityChats) {
        self.settings = settings
        self.hooks = hooks
        self.chats = chats
    }

    /// Feeds `view` until the task is cancelled (the window's sidebar bridge owns it).
    public func start(_ view: SidebarView) -> Task<Void, Never> {
        view.onPriorityAction = { [weak self] action in self?.perform(action) }
        // task-owner: the sidebar bridge (cancelled in teardown); event-driven (Observation)
        // The task holds the feed: it lives as long as the window's sidebar shows it.
        return Task { [self, weak view] in
            for await panel in ObservationStream({ self.panel() }) {
                view?.showPriority(panel)
                // The chats the rows were built from (`panel`), else (the view not installed) built now.
                let built = self.built ?? chats.snapshot()
                self.built = nil
                scheduleNextChange(built)
                // A store is empty while its watch is down or not up yet (a machine's tree while it
                // is not connected): pruning then would drop the marks of every chat it reports, so
                // prune only while every one is live.
                if chats.complete(built) { marks.prune(keeping: Set(built.lanes.map(\.id))) }
            }
        }
    }

    /// The chats the last `panel` built, for that change's next wake and prune.
    private var built: AgentPriorityChats.Snapshot?

    /// What the sidebar shows now; nil while the view is not installed. Read inside an observation
    /// scope. With the bell off only the rows that need the person are kept (for the bell's dot), so
    /// a working chat's progress redraws nothing.
    func panel() -> SidebarPriorityPanel? {
        guard settings.enabled() else { return nil }
        let shown = settings.shown(), state = marks.state
        _ = clock.ticks
        let built = chats.snapshot()
        self.built = built
        let entries = chats.entries(built, now: Date())
        return SidebarPriorityPanel(entries: shown ? entries : entries.filter(\.needsAttention), shown: shown,
                                    collapsed: state.collapsed, shortcut: hooks.shortcut())
    }

    /// A row's buttons run their registered actions (`Hooks.rowAction`); the fold, the bell and a
    /// dragged row's place are the view's own.
    func perform(_ action: SidebarPriorityAction) {
        switch action {
        case .open(let id): if let lane = chats.lane(id) { hooks.open(lane) }
        case .markRead, .togglePin, .snooze, .archive: hooks.rowAction(action)
        case .setCollapsed(let collapsed): marks.setCollapsed(collapsed)
        case .place(let id, let order): marks.place(id, in: order)
        case .toggleShown: hooks.toggleShown()
        }
    }

    /// Wakes at the next change no lane or mark makes (a snooze end, an idle chat aging out), and
    /// again after it: a wake that leaves the rows as they were (the bell off) emits nothing.
    private func scheduleNextChange(_ built: AgentPriorityChats.Snapshot) {
        let now = Date()
        guard let next = ranking.nextChange(built.lanes, marks: marks.state, now: now, failingChecks: built.failingChecks) else {
            return nextChange.cancel()
        }
        // Rounded up and a little late, so the wake never lands just before the change.
        let milliseconds = Int64((max(1, next.timeIntervalSince(now)) * 1000).rounded(.up)) + 50
        nextChange.schedule(after: .milliseconds(milliseconds)) { @MainActor [weak self] in
            guard let self else { return }
            clock.ticks += 1
            scheduleNextChange(chats.snapshot())
        }
    }
}

/// Bumped at each time-only change of the Priority rows; observed, so a bump redraws.
@Observable @MainActor
final class PriorityClock {
    var ticks = 0
}

public import CmuxNextAgentActivity
import CmuxNextCompat
public import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import os

/// The sidebar's Priority view (`sidebar.priorityView.enabled`, an App Store item, off by default):
/// every acpmux chat on this Mac, its peers and the Chief home, ranked by what needs the person
/// (`AgentPriorityRanking`), at the top of each window's sidebar while the titlebar bell is on
/// (`sidebar.priorityView.shown`). Event-driven: it redraws when a lane, a mark or the setting
/// changes, and at the next snooze end, never on a poll. The App passes the settings, the
/// shortcut, the chat jump and the acpmux archive request (its own target keeps them out of
/// CmuxNextApp, code-quality SW14).
@MainActor
public final class SidebarPriorityFeed {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.priority")

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
        /// `_acpmux/archive` for a session on the acpmux socket at the first argument.
        public var archive: @Sendable (_ socketPath: String, _ sessionId: String) async throws -> Void
        /// Runs Toggle Priority View (the bell).
        public var toggleShown: @MainActor () -> Void

        public init(shortcut: @escaping @MainActor () -> String?, open: @escaping @MainActor (AgentActivityLane) -> Void,
                    archive: @escaping @Sendable (String, String) async throws -> Void, toggleShown: @escaping @MainActor () -> Void) {
            self.shortcut = shortcut
            self.open = open
            self.archive = archive
            self.toggleShown = toggleShown
        }
    }

    private let settings: Settings
    private let hooks: Hooks
    private let marks: AgentPriorityMarks
    private let stores: [AgentLaneStore]
    private let ranking = AgentPriorityRanking()
    /// Bumped when a snooze ends or an idle chat ages out, so the rows redraw with no other change.
    private let clock = PriorityClock()
    private let nextChange = DemandTimer(owner: "sidebar-priority-next-change")

    public init(settings: Settings, hooks: Hooks, marks: AgentPriorityMarks = .shared,
                stores: [AgentLaneStore] = [.shared, .chief]) {
        self.settings = settings
        self.hooks = hooks
        self.marks = marks
        self.stores = stores
    }

    /// Feeds `view` until the task is cancelled (the window's sidebar bridge owns it).
    public func start(_ view: SidebarView) -> Task<Void, Never> {
        view.onPriorityAction = { [weak self] action in self?.perform(action) }
        // task-owner: the sidebar bridge (cancelled in teardown); event-driven (Observation)
        // The task holds the feed: it lives as long as the window's sidebar shows it.
        return Task { [self, weak view] in
            for await panel in ObservationStream({ self.panel() }) {
                view?.showPriority(panel)
                scheduleNextChange()
                // A store is empty while its watch is down or not up yet: pruning then would drop
                // the marks of every chat it reports, so prune only while every watched store is live.
                if stores.allSatisfy({ $0.live || $0.socketPath == nil }) { marks.prune(keeping: Set(lanes.map(\.id))) }
            }
        }
    }

    /// Every lane of every store, this Mac's first when an id repeats.
    var lanes: [AgentActivityLane] {
        var seen = Set<String>()
        return stores.flatMap { $0.lanes.values.sorted { $0.id < $1.id } }.filter { seen.insert($0.id).inserted }
    }

    /// What the sidebar shows now; nil while the view is not installed. Read inside an observation
    /// scope. With the bell off only the rows that need the person are kept (for the bell's dot), so
    /// a working chat's progress redraws nothing.
    func panel() -> SidebarPriorityPanel? {
        guard settings.enabled() else { return nil }
        let shown = settings.shown(), state = marks.state
        _ = clock.ticks
        let entries = ranking.entries(lanes, marks: state, now: Date(), failingChecks: failingChecks)
        return SidebarPriorityPanel(entries: shown ? entries : entries.filter(\.needsAttention), shown: shown,
                                    collapsed: state.collapsed, shortcut: hooks.shortcut())
    }

    func perform(_ action: SidebarPriorityAction) {
        switch action {
        case .open(let id): if let lane = lane(id) { hooks.open(lane) }
        case .markRead(let id): if let lane = lane(id) { marks.markRead(lane) }
        case .togglePin(let id): marks.togglePin(id)
        case .snooze(let id): if let lane = lane(id) { marks.snooze(lane) }
        case .archive(let id): archive(id)
        case .setCollapsed(let collapsed): marks.setCollapsed(collapsed)
        case .toggleShown: hooks.toggleShown()
        }
    }

    private func lane(_ id: String) -> AgentActivityLane? {
        stores.lazy.compactMap { $0.lanes[id] }.first
    }

    /// Hides the chat here at once, then archives it in the acpmux that reports it (this Mac's or
    /// the Chief home's). A refusal (a peer's chat this acpmux does not own, a dropped socket)
    /// shows the chat again.
    private func archive(_ id: String) {
        guard let socketPath = stores.first(where: { $0.lanes[id] != nil })?.socketPath else { return }
        marks.archive(id)
        let archive = hooks.archive, marks = marks
        // task-owner: one archive request; ends when acpmux answers or its deadline passes
        Task {
            do { try await archive(socketPath, id) } catch {
                Self.logger.error("priority archive failed: \(String(describing: error), privacy: .public)")
                marks.unarchive(id)
            }
        }
    }

    /// Wakes at the next change no lane or mark makes (a snooze end, an idle chat aging out), and
    /// again after it: a wake that leaves the rows as they were (the bell off) emits nothing.
    private func scheduleNextChange() {
        let now = Date()
        guard let next = ranking.nextChange(lanes, marks: marks.state, now: now, failingChecks: failingChecks) else {
            return nextChange.cancel()
        }
        // Rounded up and a little late, so the wake never lands just before the change.
        let milliseconds = Int64((max(1, next.timeIntervalSince(now)) * 1000).rounded(.up)) + 50
        nextChange.schedule(after: .milliseconds(milliseconds)) { @MainActor [weak self] in
            self?.clock.ticks += 1
            self?.scheduleNextChange()
        }
    }

    /// The chats with a pull request whose checks fail (Red CI), as the session tree's badge last
    /// read them (`SidebarSessionTreeFeed.checksFailing`): no GitHub read of its own.
    private var failingChecks: Set<String> {
        let tree = SidebarSessionTreeFeed.shared
        return Set(lanes.filter { tree.checksFailing($0) }.map(\.id))
    }
}

/// Bumped at each time-only change of the Priority rows; observed, so a bump redraws.
@Observable @MainActor
final class PriorityClock {
    var ticks = 0
}

import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Observation
import os

/// The sidebar's Priority view (`sidebar.priorityView.enabled`, an App Store item, off by default):
/// every acpmux chat on this Mac, its peers and the Chief home, ranked by what needs the person
/// (`AgentPriorityRanking`), at the top of each window's sidebar while the titlebar bell is on
/// (`sidebar.priorityView.shown`). Event-driven: it redraws when a lane, a mark or the setting
/// changes, and at the next snooze end, never on a poll.
@MainActor
final class SidebarPriorityFeed {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.priority")
    static let toggleAction: ActionID = "sidebar.priorityView.toggle"

    private weak var services: AppServices?
    private let marks: AgentPriorityMarks
    private let stores: [AgentLaneStore]
    private let ranking = AgentPriorityRanking()
    /// The time ranking reads; bumped when a snooze ends so its chat comes back.
    private let clock = PriorityClock()
    private let snoozeEnd = DemandTimer(owner: "sidebar-priority-snooze")

    init(services: AppServices, marks: AgentPriorityMarks = .shared,
         stores: [AgentLaneStore] = [.shared, ChatsFeed.chiefLanes]) {
        self.services = services
        self.marks = marks
        self.stores = stores
    }

    /// Feeds `view` until the task is cancelled (the window's sidebar bridge owns it).
    func start(_ view: SidebarView) -> Task<Void, Never> {
        view.onPriorityAction = { [weak self] action in self?.perform(action) }
        // task-owner: the sidebar bridge (cancelled in teardown); event-driven (Observation)
        // The task holds the feed: it lives as long as the window's sidebar shows it.
        return Task { [self, weak view] in
            for await panel in ObservationStream({ self.panel() }) {
                view?.showPriority(panel)
                scheduleSnoozeEnd()
                let ids = Set(lanes.map(\.id))
                if !ids.isEmpty { marks.prune(keeping: ids) }
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
        let preferences = DesignSettings.shared.sidebarSections
        guard preferences.priorityViewEnabled else { return nil }
        let shown = preferences.priorityViewShown, state = marks.state
        let entries = ranking.entries(lanes, marks: state, now: clock.now)
        return SidebarPriorityPanel(entries: shown ? entries : entries.filter(\.needsAttention), shown: shown, collapsed: state.collapsed,
                                    shortcut: services?.registry.shortcutDisplay(for: Self.toggleAction))
    }

    func perform(_ action: SidebarPriorityAction) {
        switch action {
        case .open(let id):
            guard let lane = lane(id) else { return }
            services?.agentActivityPage.jump(to: lane)
        case .markRead(let id): if let lane = lane(id) { marks.markRead(lane) }
        case .togglePin(let id): marks.togglePin(id)
        case .snooze(let id): if let lane = lane(id) { marks.snooze(lane) }
        case .archive(let id): archive(id)
        case .setCollapsed(let collapsed): marks.setCollapsed(collapsed)
        case .toggleShown: _ = services?.registry.perform(Self.toggleAction, invocation: ActionInvocation(origin: .user))
        }
    }

    private func lane(_ id: String) -> AgentActivityLane? {
        stores.lazy.compactMap { $0.lanes[id] }.first
    }

    /// Hides the chat here at once, then archives it in acpmux (this Mac's or the Chief home's).
    private func archive(_ id: String) {
        marks.archive(id)
        guard let services else { return }
        let chief = AgentLaneStore.shared.lanes[id] == nil && ChatsFeed.chiefLanes.lanes[id] != nil
        let environment = chief ? ChiefHomeAcpmux.environment(home: ChiefHome.resolve(tag: services.environment.tag))
            : QuitAgents.environment(services)
        guard let socketPath = environment?.socketPath else { return }
        let archiver = AcpmuxChatArchive(socketPath: socketPath)
        // task-owner: one archive request; ends when acpmux answers or its deadline passes
        Task {
            do { try await archiver.archive(sessionId: id) } catch {
                Self.logger.error("priority archive failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Wakes once when the earliest snooze ends, so that chat comes back without another change.
    private func scheduleSnoozeEnd() {
        let now = Date()
        guard let next = marks.state.snoozed.values.map(\.until).filter({ $0 > now }).min() else { return snoozeEnd.cancel() }
        let seconds = max(1, next.timeIntervalSince(now))
        snoozeEnd.schedule(after: .milliseconds(Int64(seconds * 1000))) { @MainActor [weak self] in
            self?.clock.now = Date()
        }
    }

    /// The Toggle Priority View action: flips `sidebar.priorityView.shown` while the view is installed.
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let preferences = { @MainActor @Sendable in context.services.settings?.snapshot.sidebarSections ?? .defaults }
        registry.bind(toggleAction, unavailable: { preferences().priorityViewEnabled ? nil : SidebarSectionStrings.priorityViewOff }) { invocation in
            guard let settings = context.services.settings else { return }
            let path = SidebarPriorityViewSetting.shownPath
            try AppearanceHandlers.requireUnmanaged(path, context)
            guard let descriptor = SettingsSchema.descriptor(for: path) else { return }
            let shown = !preferences().priorityViewShown, writer = SettingWriter(invocation.origin)
            // task-owner: one settings write; ends when the write lands
            Task {
                do { try await settings.setSetting(descriptor, to: .bool(shown), by: writer) } catch {
                    logger.error("priority view toggle failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}

/// The clock the Priority ranking reads (snoozes and the idle horizon); observed, so a bump redraws.
@Observable @MainActor
final class PriorityClock {
    var now = Date()
}

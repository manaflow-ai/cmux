import AppKit
import Combine

/// One workspace with a coding agent, as the empty Chief conversation lists
/// it under "Your agents": the workspace, the name the sidebar shows, and
/// one word for what its agents are doing. Mapped from the same per-panel
/// agent lifecycle the sidebar draws (``Workspace/agentLifecycleStatesByPanelId``)
/// and the workspace's unread notifications, so Home never says something
/// the sidebar does not. (cmux-next `HomeAgentGlance`, per workspace here.)
struct ChiefAgentGlance: Equatable {
    /// Most urgent first: the list's order.
    enum Status: Int, Comparable {
        /// Waits for the user: a question, a permission, input, or an error
        /// (the sidebar shows agent errors as needs-input too).
        case needsYou
        /// Finished, with a notification the user has not read.
        case done
        /// Working on a turn, or background work pending.
        case working
        /// Nothing to report.
        case idle

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var workspaceId: UUID
    var title: String
    var status: Status
    /// False for a plain workspace listed because no workspace has an agent.
    var hasAgent = true

    /// At most `limit` agents, most urgent first; equal statuses keep the
    /// sidebar's order.
    static func shortlist(_ agents: [ChiefAgentGlance], limit: Int = 5) -> [ChiefAgentGlance] {
        Array(agents.enumerated().sorted { ($0.element.status, $0.offset) < ($1.element.status, $1.offset) }
            .prefix(limit).map(\.element))
    }

    /// Workspaces without agents as idle rows, in sidebar order, at most
    /// `limit`. cmux-next's glance lists agents only (`HomeAgentGlances`);
    /// classic Home also lists plain workspaces when there are no agents,
    /// because the sidebar's workspace rows are hidden while Home is selected.
    static func plainWorkspaces(_ workspaces: [(id: UUID, title: String)], limit: Int = 5) -> [ChiefAgentGlance] {
        workspaces.prefix(limit).map { ChiefAgentGlance(workspaceId: $0.id, title: $0.title, status: .idle, hasAgent: false) }
    }

    /// The name a workspace row shows: the custom title, else the sidebar's
    /// title, except when that title is only a shell's path ("~", "~/src",
    /// "/tmp") or the new-workspace placeholder ("Terminal", what a restored
    /// workspace shows before its shell reports a title): then the folder's
    /// name (the working directory's, for the placeholder), or "Home folder"
    /// for the home directory, so the default workspace never reads as a
    /// bare "~" or "Terminal".
    static func displayTitle(customTitle: String?, title: String, currentDirectory: String,
                             home: String = NSHomeDirectory()) -> String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty { return custom }
        let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPath = shown == "~" || shown.hasPrefix("~/") || shown.hasPrefix("/")
        // `Workspace.init`'s default title.
        let isPlaceholder = shown == "Terminal"
        guard shown.isEmpty || isPath || isPlaceholder else { return shown }
        let directory = currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        // The placeholder with no known directory stays as it is.
        if isPlaceholder, directory.isEmpty { return shown }
        let path = isPath ? (shown as NSString).expandingTildeInPath : (directory as NSString).expandingTildeInPath
        let standardized = (path as NSString).standardizingPath
        if standardized.isEmpty || standardized == (home as NSString).standardizingPath {
            return String(localized: "chief.firstRun.workspace.homeFolder", defaultValue: "Home folder")
        }
        let name = (standardized as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? standardized : name
    }

    /// One workspace's status from its panels' agent lifecycles; nil when no
    /// built-in agent reports in it.
    static func status(lifecycles: [UUID: [String: AgentHibernationLifecycleState]], unread: Bool) -> Status? {
        let states = lifecycles.values.flatMap { $0.filter { AgentHibernationLifecycleStatusKeys.isAllowed($0.key) }.values }
        if states.contains(.needsInput) { return .needsYou }
        if states.contains(.running) || states.contains(.backgroundWorkPending) { return .working }
        if states.contains(.idle) { return unread ? .done : .idle }
        return nil
    }
}

/// Reads and opens the agents of the window the first-run panel is in.
@MainActor
enum ChiefAgentGlanceSource {
    /// The window's workspaces (the app's active ones outside a main window).
    static func tabManager(for window: NSWindow?) -> TabManager? {
        guard let app = AppDelegate.shared else { return nil }
        if let window, let context = app.mainWindowContexts.values.first(where: { $0.tabManager.window === window }) {
            return context.tabManager
        }
        return app.tabManager
    }

    /// Every workspace with an agent, in sidebar order. With no agent
    /// anywhere, the first workspaces as idle plain rows instead
    /// (``ChiefAgentGlance/plainWorkspaces(_:)``), so the panel always offers
    /// a way back to existing workspaces.
    static func glances(in tabManager: TabManager) -> [ChiefAgentGlance] {
        let notifications = TerminalNotificationStore.shared
        let agents = tabManager.tabs.compactMap { workspace -> ChiefAgentGlance? in
            let unread = notifications.unreadCount(forTabId: workspace.id) > 0
            guard let status = ChiefAgentGlance.status(lifecycles: workspace.agentLifecycleStatesByPanelId,
                                                       unread: unread) else { return nil }
            return ChiefAgentGlance(workspaceId: workspace.id, title: title(of: workspace), status: status)
        }
        guard agents.isEmpty else { return agents }
        return ChiefAgentGlance.plainWorkspaces(tabManager.tabs.map { (id: $0.id, title: title(of: $0)) })
    }

    private static func title(of workspace: Workspace) -> String {
        ChiefAgentGlance.displayTitle(customTitle: workspace.customTitle, title: workspace.title,
                                      currentDirectory: workspace.currentDirectory)
    }

    /// Shows the workspace, leaving Home even when it is already the selected one.
    static func open(_ workspaceId: UUID, in tabManager: TabManager) {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return }
        tabManager.selectWorkspace(workspace)
        AppDelegate.shared?.leaveChiefHome(in: tabManager)
    }

    /// "⌃1…9" from the configured Select Workspace 1…9 shortcut; nil when unbound or a chord.
    static func workspaceNumberKeys() -> String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return shortcut.modifierDisplayString + "1…9"
    }

    /// The New Workspace shortcut ("Open a terminal" makes a workspace); nil when unbound.
    static func newWorkspaceKeys() -> String? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .newTab)
        return shortcut.isUnbound ? nil : shortcut.displayString
    }
}

/// Calls `onChange` (coalesced to once per main-queue turn) while attached:
/// when the window's workspaces change, an agent's lifecycle changes in any
/// of them, or notifications are read or arrive.
@MainActor
final class ChiefAgentGlanceObserver {
    var onChange: () -> Void = {}
    private(set) weak var tabManager: TabManager?
    private var subscriptions: [AnyCancellable] = []
    private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var isScheduled = false

    func attach(_ tabManager: TabManager?) {
        guard tabManager !== self.tabManager || (tabManager != nil && subscriptions.isEmpty) else { return }
        detach()
        guard let tabManager else { return }
        self.tabManager = tabManager
        subscriptions = [
            tabManager.objectWillChange.sink { [weak self] _ in self?.scheduleFromAnyThread() },
            TerminalNotificationStore.shared.objectWillChange.sink { [weak self] _ in self?.scheduleFromAnyThread() },
        ]
        observeWorkspaces()
    }

    func detach() {
        subscriptions.removeAll()
        for task in lifecycleTasks.values { task.cancel() }
        lifecycleTasks.removeAll()
        tabManager = nil
    }

    private nonisolated func scheduleFromAnyThread() {
        // objectWillChange fires before the change lands: read on the next main-queue turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    private func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isScheduled = false
                guard self.tabManager != nil else { return }
                self.observeWorkspaces()
                self.onChange()
            }
        }
    }

    /// One lifecycle stream per workspace; streams of closed workspaces end.
    private func observeWorkspaces() {
        guard let tabManager else { return }
        let workspaces = tabManager.tabs
        let ids = Set(workspaces.map(\.id))
        for (id, task) in lifecycleTasks where !ids.contains(id) {
            task.cancel()
            lifecycleTasks[id] = nil
        }
        for workspace in workspaces where lifecycleTasks[workspace.id] == nil {
            let changes = workspace.sidebarAgentRuntimeObservation.changes()
            lifecycleTasks[workspace.id] = Task { @MainActor [weak self] in
                for await _ in changes {
                    self?.schedule()
                }
            }
        }
    }
}

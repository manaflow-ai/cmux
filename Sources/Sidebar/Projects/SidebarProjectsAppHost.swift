import AppKit
import Combine
import CmuxFoundation
import CmuxNotifications
import CmuxSettings
import CmuxSidebar
import CmuxSurfaceCatalogModel
import CmuxWorkspaces
import SwiftUI

/// Shows a preview sidebar (Projects, Panes, Flush, Machine tabs) in place of the
/// native workspace list while one is chosen (sidebar button's right-click menu).
struct SidebarProjectsGate<Fallback: View>: View {
    @AppStorage(SidebarProjectsAppHost.layoutKey) private var layout = ""
    /// Before the other layouts, Projects had its own on/off switch.
    @AppStorage(SidebarProjectsAppHost.enabledKey) private var legacyProjects = false
    let tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    @ViewBuilder let fallback: () -> Fallback

    var body: some View {
        let active = layout.isEmpty && legacyProjects ? "projects" : layout
        if SidebarProjectsAppHost.layouts.contains(active) {
            SidebarProjectsAppHost(tabManager: tabManager, sidebarUnread: sidebarUnread, layout: active)
        } else if SidebarProjectsAppHost.machineLayouts.contains(active) {
            // Codex and Machine rail rearrange the real list itself (VerticalTabsSidebar's
            // machineLayoutPass); this adds the strips around it.
            SidebarMachineLayoutAppChrome(tabManager: tabManager, sidebarUnread: sidebarUnread, layout: active, list: fallback)
        } else {
            fallback()
        }
    }
}

/// Codex and Machine rail in the app: the strips around the real list (Codex's
/// New workspace and Search, or the machine rail and the machine's name), fed
/// the window's machines.
struct SidebarMachineLayoutAppChrome<Content: View>: View {
    @ObservedObject var tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    let layout: String
    @ViewBuilder let list: () -> Content
    @ObservedObject private var state = SidebarMachineLayoutState.shared

    var body: some View {
        let unread = sidebarUnread.snapshot
        let places = tabManager.tabs.map { ($0.id, SidebarProjectsAppHost.place($0)) }
        let order = Self.order(places.map(\.1))
        let machines = order.map { place in
            SidebarMachineRail.Machine(place: place, unread: places.filter { $0.1 == place }.reduce(0) { $0 + unread.unreadCount(forWorkspaceId: $1.0) })
        }
        let manager = tabManager
        SidebarMachineLayoutChrome(
            layout: layout,
            machines: machines,
            count: places.filter { $0.1 == state.railMachine }.count,
            topInset: SidebarWorkspaceListMetrics.firstRowTopOffset + 8,
            listTopInset: SidebarWorkspaceListMetrics.scrollTopInset,
            bottomInset: SidebarWorkspaceScrollInsets.workspaceList.bottom,
            newWorkspace: { SidebarProjectsAppHost.newWorkspace(group: nil, place: nil, in: manager) },
            search: { NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: NSApp.keyWindow) },
            newMachine: { _ = AppDelegate.shared?.performNewCloudMachineAction(tabManager: manager, debugSource: "sidebar.machineRail", destination: nil) },
            list: list
        )
        // A machine that went away leaves the rail on This Mac.
        .onChange(of: order) { _, places in
            if !places.contains(state.railMachine) { state.railMachine = .local }
        }
    }

    /// This Mac, then Cloud machines, then other Macs, each in first-seen order.
    private static func order(_ places: [SidebarProjectsRow.Place]) -> [SidebarProjectsRow.Place] {
        var seen: [SidebarProjectsRow.Place] = [.local]
        for place in places where !seen.contains(place) { seen.append(place) }
        let rank: (SidebarProjectsRow.Place) -> Int = { place in
            switch place {
            case .local: return 0
            case .cloud: return 1
            case .device: return 2
            }
        }
        return seen.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// The app's data in, Projects sidebar out: rows from the window's workspaces,
/// projects from its workspace groups, actions through TabManager and the
/// app's own Cloud and notification paths.
struct SidebarProjectsAppHost: View {
    static let enabledKey = "sidebarProjectsEnabled"
    static let layoutKey = "sidebarPreviewLayout"
    /// The preview sidebars, in menu order.
    static let layouts = ["projects", "panes", "flush", "machineTabs"]
    /// The previews that rearrange the native list itself.
    static let machineLayouts = ["codex", "rail"]

    /// The preview sidebar in use, nil for the native list.
    static func activeLayout(defaults: UserDefaults = .standard) -> String? {
        let layout = defaults.string(forKey: layoutKey) ?? ""
        let active = layout.isEmpty && defaults.bool(forKey: enabledKey) ? "projects" : layout
        return (layouts + machineLayouts).contains(active) ? active : nil
    }

    /// A new workspace in a project (nil: none) on a machine (nil or This Mac: here),
    /// pinned when asked. Other Macs can't take one from here yet, so they get a local one.
    static func newWorkspace(group: UUID?, place: SidebarProjectsRow.Place?, pinned: Bool = false, in manager: TabManager) {
        if case .cloud(let name) = place,
           let vmID = manager.tabs.first(where: { $0.hostLabel.kind == .cloud && $0.hostLabel.label == name })?.cloudVMID {
            let destination = group.map {
                CloudWorkspaceGroupDestination(tabManager: manager, groupId: $0, placement: .end, referenceWorkspaceId: nil, initialWorkspaceId: nil)
            }
            _ = AppDelegate.shared?.performNewCloudWorkspaceOnCurrentMachineAction(tabManager: manager, vmID: vmID, destination: destination)
            return
        }
        guard let created = manager.addWorkspaceIfActive(placementOverride: .end) else { return }
        if let group { manager.addWorkspaceToGroup(workspaceId: created.id, groupId: group, placement: .end) }
        if pinned { manager.setPinned(created, pinned: true) }
    }

    @ObservedObject var tabManager: TabManager
    let sidebarUnread: SidebarUnreadModel
    var layout = "projects"
    @StateObject private var live = Live()

    var body: some View {
        let _ = live.revision
        // Read inside body so SwiftUI tracks unread changes (SidebarUnreadModel is @Observable).
        let unread = sidebarUnread.snapshot
        let tabs = tabManager.tabs
        let groupsById = Dictionary(tabManager.workspaceGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = tabs.map { row($0, unread: unread, groups: groupsById) }
        let groups = orderedGroups(tabs: tabs, groupsById: groupsById)
        let actions = self.actions(tabs: tabs)
        Group {
            switch layout {
            case "panes": SidebarPanesView(input: layoutInput(rows: rows, groups: groups, actions: actions))
            case "flush": SidebarFlushView(input: layoutInput(rows: rows, groups: groups, actions: actions))
            case "machineTabs": SidebarMachineTabsView(input: layoutInput(rows: rows, groups: groups, actions: actions))
            default:
                SidebarProjectsView(
                    rows: rows,
                    groups: groups,
                    machines: [],
                    selectedId: tabManager.selectedTabId,
                    topInset: Self.topInset,
                    bottomInset: SidebarWorkspaceScrollInsets.workspaceList.bottom,
                    showsOwnFooter: false,
                    actions: actions,
                    agentIcon: Self.agentIcon
                )
            }
        }
        .onAppear { live.watch(tabManager) }
        .onChange(of: tabs.map(\.id)) { _, _ in live.watch(tabManager) }
    }

    // MARK: Data

    /// Clear the titlebar (traffic lights, sidebar buttons) with room to spare. The native
    /// list's inset is tighter because its rows carry their own top padding.
    private static let topInset = SidebarWorkspaceListMetrics.firstRowTopOffset + 8

    /// What Panes, Flush and Machine tabs read on top of the rows and projects.
    private func layoutInput(rows: [SidebarProjectsRow], groups: [SidebarProjectsGroup], actions: SidebarProjectsActions) -> SidebarLayoutInput {
        let manager = tabManager
        var more = SidebarLayoutActions()
        more.focusPane = { id, pane in
            guard let workspace = manager.tabs.first(where: { $0.id == id }) else { return }
            manager.selectWorkspace(workspace)
            if let panelId = UUID(uuidString: pane.id) { manager.focusPanel(workspaceId: id, panelId: panelId) }
        }
        more.openPort = { id, port in
            // Same as a port on a native row: the cmux browser when that setting is on.
            guard let url = URL(string: "http://localhost:\(port)") else { return }
            if BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(),
               manager.openBrowser(inWorkspace: id, url: url, preferSplitRight: true, insertAtEnd: true) != nil {
                return
            }
            NSWorkspace.shared.open(url)
        }
        return SidebarLayoutInput(
            rows: rows,
            groups: groups,
            selectedId: manager.selectedTabId,
            topInset: Self.topInset,
            bottomInset: SidebarWorkspaceScrollInsets.workspaceList.bottom,
            actions: actions,
            more: more,
            agentIcon: Self.agentIcon,
            panes: { id in manager.tabs.first { $0.id == id }.map(Self.panes) ?? [] },
            machineFacts: Self.machineFacts
        )
    }

    /// A workspace's panes in split order: agents (by the agent running there),
    /// shells with their directory, browsers, anything else by its tab title.
    private static func panes(_ workspace: Workspace) -> [SidebarLayoutPane] {
        let states = workspace.agentLifecycleStatesByPanelId
        var result: [SidebarLayoutPane] = []
        for paneId in workspace.bonsplitController.allPaneIds {
            for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                let id = panelId.uuidString
                let agent = (states[panelId] ?? [:])
                    .filter { AgentHibernationLifecycleStatusKeys.isAllowed($0.key) }
                    .max { rank($0.value) < rank($1.value) }
                if let agent {
                    let status: SidebarProjectsRow.Status
                    switch agent.value {
                    case .needsInput: status = .needsInput
                    case .running, .backgroundWorkPending: status = .working
                    case .idle, .unknown: status = .idle
                    }
                    result.append(SidebarLayoutPane(id: id, kind: .agent(agent.key == "claude_code" ? "claude" : agent.key), text: tab.title, status: status))
                } else if workspace.panels[panelId] is BrowserPanel {
                    result.append(SidebarLayoutPane(id: id, kind: .browser, text: tab.title))
                } else if workspace.panels[panelId] is TerminalPanel {
                    let directory = workspace.reportedPanelDirectory(panelId: panelId).map(shortDirectory)
                    result.append(SidebarLayoutPane(id: id, kind: .shell, text: tab.title, detail: directory))
                } else {
                    result.append(SidebarLayoutPane(id: id, kind: .other, text: tab.title))
                }
            }
        }
        return result
    }

    /// What the card says about a machine. Nothing is invented: the Cloud
    /// service's state and size aren't wired in yet.
    private static func machineFacts(_ place: SidebarProjectsRow.Place) -> (state: String?, spec: String?) {
        switch place {
        case .local:
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return (nil, "macOS \(version.majorVersion).\(version.minorVersion)")
        case .cloud:
            return (nil, String(localized: "sidebar.layouts.machine.cloud", defaultValue: "Cloud machine"))
        case .device:
            return (nil, String(localized: "sidebar.layouts.machine.device", defaultValue: "Another Mac on your account"))
        }
    }

    /// "now", "4m", "3h", "2d" since the last message sent in the workspace.
    private static func age(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return String(localized: "sidebar.layouts.age.now", defaultValue: "now") }
        if seconds < 3600 { return String(localized: "sidebar.layouts.age.minutes", defaultValue: "\(Int(seconds / 60))m") }
        if seconds < 86400 { return String(localized: "sidebar.layouts.age.hours", defaultValue: "\(Int(seconds / 3600))h") }
        return String(localized: "sidebar.layouts.age.days", defaultValue: "\(Int(seconds / 86400))d")
    }

    /// Projects in the order their workspaces first appear, like the native list.
    private func orderedGroups(tabs: [Workspace], groupsById: [UUID: WorkspaceGroup]) -> [SidebarProjectsGroup] {
        var seen: [UUID] = []
        for tab in tabs { if let id = tab.groupId, groupsById[id] != nil, !seen.contains(id) { seen.append(id) } }
        for group in tabManager.workspaceGroups where !seen.contains(group.id) { seen.append(group.id) }
        return seen.compactMap { id in
            guard let group = groupsById[id] else { return nil }
            return SidebarProjectsGroup(
                id: id, name: group.name, isPinned: group.isPinned, color: group.customColor,
                anchorId: group.liveAnchorWorkspaceId
            )
        }
    }

    private func row(_ workspace: Workspace, unread: SidebarUnreadSnapshot, groups: [UUID: WorkspaceGroup]) -> SidebarProjectsRow {
        var states: [String: AgentHibernationLifecycleState] = [:]
        for byKind in workspace.agentLifecycleStatesByPanelId.values {
            for (kind, state) in byKind where AgentHibernationLifecycleStatusKeys.isAllowed(kind) {
                // Keep the most active state per agent kind.
                if states[kind] == nil || Self.rank(state) > Self.rank(states[kind]!) { states[kind] = state }
            }
        }
        let count = unread.unreadCount(forWorkspaceId: workspace.id)
        let status: SidebarProjectsRow.Status
        if states.values.contains(.needsInput) {
            status = .needsInput
        } else if states.values.contains(where: { $0 == .running || $0 == .backgroundWorkPending }) {
            status = .working
        } else {
            status = count > 0 ? .done : .idle
        }
        // The busiest agent first: it is the one a row's leading icon shows.
        let agents = states.sorted { a, b in Self.rank(a.value) != Self.rank(b.value) ? Self.rank(a.value) > Self.rank(b.value) : a.key < b.key }.map(\.key)
        return SidebarProjectsRow(
            id: workspace.id,
            title: workspace.title,
            groupId: workspace.groupId.flatMap { groups[$0] != nil ? $0 : nil },
            isPinned: workspace.isPinned,
            status: status,
            unread: count,
            agents: agents.map { $0 == "claude_code" ? "claude" : $0 },
            place: Self.place(workspace),
            branch: workspace.gitBranch?.branch,
            directory: Self.shortDirectory(workspace.currentDirectory),
            message: unread.latestNotificationText(forWorkspaceId: workspace.id) ?? workspace.latestConversationMessage,
            age: Self.age(workspace.latestSubmittedAt),
            ports: workspace.listeningPorts
        )
    }

    private static func rank(_ state: AgentHibernationLifecycleState) -> Int {
        switch state {
        case .needsInput: return 3
        case .running, .backgroundWorkPending: return 2
        case .idle: return 1
        case .unknown: return 0
        }
    }

    static func place(_ workspace: Workspace) -> SidebarProjectsRow.Place {
        let host = workspace.hostLabel
        switch host.kind {
        case .cloud: return .cloud(host.label)
        case .ssh: return .device(host.label)
        case .local:
            // Another Mac signed in to the same account.
            let state = workspace.cloudBindingState
            if let device = state.projectedResources.values.map(\.machine).first(where: \.isDevice) {
                return .device(state.machineNames[device.rawValue] ?? SurfaceCatalog.shared.machineInfo(for: device)?.name ?? device.rawValue)
            }
            return .local
        }
    }

    private static func shortDirectory(_ path: String) -> String {
        let home = NSHomeDirectory()
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        let parts = short.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : short
    }

    private static func agentIcon(_ kind: String) -> NSImage? {
        let assets = ["claude": "Claude", "codex": "Codex", "opencode": "OpenCode", "amp": "Amp", "cursor": "Cursor",
                      "gemini": "Gemini", "copilot": "Copilot", "factory": "Factory", "grok": "Grok", "kiro": "Kiro",
                      "kimi": "Kimi", "pi": "Pi", "omp": "Pi", "qoder": "Qoder", "codebuddy": "CodeBuddy",
                      "antigravity": "Antigravity", "rovodev": "RovoDev", "hermes-agent": "HermesAgent"]
        return assets[kind].flatMap { NSImage(named: "AgentIcons/" + $0) }
    }

    // MARK: Actions

    private func actions(tabs: [Workspace]) -> SidebarProjectsActions {
        let manager = tabManager
        let notifications = TerminalNotificationStore.shared
        func workspace(_ id: UUID) -> Workspace? { manager.tabs.first { $0.id == id } }
        func destination(_ group: UUID?) -> CloudWorkspaceGroupDestination? {
            group.map { CloudWorkspaceGroupDestination(tabManager: manager, groupId: $0, placement: .end, referenceWorkspaceId: nil, initialWorkspaceId: nil) }
        }

        var actions = SidebarProjectsActions()
        actions.select = { id in if let workspace = workspace(id) { manager.selectWorkspace(workspace) } }
        actions.newWorkspace = { group, place in Self.newWorkspace(group: group, place: place, in: manager) }
        actions.newCloudMachine = { group in
            _ = AppDelegate.shared?.performNewCloudMachineAction(tabManager: manager, debugSource: "sidebar.projects", destination: destination(group))
        }
        actions.reorderRows = { old, new in
            // The moved workspaces trade places among the slots they held.
            var next = new.makeIterator()
            let moving = Set(old)
            let order = manager.tabs.map { moving.contains($0.id) ? (next.next() ?? $0.id) : $0.id }
            _ = manager.reorderWorkspaces(orderedWorkspaceIds: order)
        }
        actions.reorderGroups = { newOrder in
            // Grouped workspaces trade places by project; everything else stays put.
            let rank = Dictionary(uniqueKeysWithValues: newOrder.enumerated().map { ($1, $0) })
            let grouped = manager.tabs.enumerated().filter { $0.element.groupId.flatMap { rank[$0] } != nil }
            let sorted = grouped.sorted { a, b in
                let ra = rank[a.element.groupId!]!, rb = rank[b.element.groupId!]!
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element.id)
            var next = sorted.makeIterator()
            let order = manager.tabs.map { tab in tab.groupId.flatMap { rank[$0] } != nil ? (next.next() ?? tab.id) : tab.id }
            _ = manager.reorderWorkspaces(orderedWorkspaceIds: order)
        }
        actions.togglePin = { manager.togglePin(tabId: $0) }
        actions.toggleRead = { id in
            if notifications.canMarkWorkspaceRead(forTabIds: [id]) {
                notifications.markRead(forTabId: id)
            } else if notifications.canMarkWorkspaceUnread(forTabIds: [id]) {
                notifications.markUnread(forTabId: id)
            }
        }
        actions.newProject = { id in
            let name = String(localized: "sidebar.projects.newProjectName", defaultValue: "New Project")
            if let id {
                _ = manager.createWorkspaceGroup(name: name, childWorkspaceIds: [id], selectAnchor: false)
            } else {
                _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: manager)
            }
        }
        actions.moveToProject = { id, group in manager.addWorkspaceToGroup(workspaceId: id, groupId: group) }
        actions.removeFromProject = { manager.removeWorkspaceFromGroup(workspaceId: $0) }
        actions.close = { _ = manager.closeWorkspaceWithConfirmation(tabId: $0) }
        actions.toggleProjectPin = { manager.toggleWorkspaceGroupPinned(groupId: $0) }
        actions.markProjectRead = { group in
            for tab in manager.tabs where tab.groupId == group && notifications.canMarkWorkspaceRead(forTabIds: [tab.id]) {
                notifications.markRead(forTabId: tab.id)
            }
        }
        actions.ungroupProject = { _ = manager.ungroupWorkspaceGroup(groupId: $0) }
        actions.deleteProject = { groupId in
            // Like the native group header: closing its workspaces always asks first.
            guard let confirmation = manager.workspaceGrouping.deletionConfirmation(groupId: groupId) else { return }
            let isPinned = manager.workspaceGroups.first { $0.id == groupId }?.isPinned ?? false
            if isPinned || confirmation.containedWorkspaceCount > 0 {
                guard confirmDeleteWorkspaceGroup(groupName: confirmation.groupName, memberCount: confirmation.containedWorkspaceCount) else { return }
            }
            manager.workspaceGrouping.deleteWorkspaceGroup(confirmed: confirmation)
        }
        actions.search = { NotificationCenter.default.post(name: .commandPaletteSwitcherRequested, object: NSApp.keyWindow) }
        actions.showCloudMachines = {
            // A toggle: a second click closes the panel. On another right sidebar tab it switches to Cloud.
            let context = AppDelegate.shared?.mainWindowContext(for: manager)
            if let state = context?.fileExplorerState, state.isVisible, state.mode == .machines {
                state.setVisible(false)
            } else if AppDelegate.shared?.revealCloudMachinesSidebar(preferredWindow: context?.window ?? NSApp.keyWindow) != true {
                NSSound.beep()
            }
        }
        actions.openSettings = { AppDelegate.shared?.openPreferencesWindow(debugSource: "sidebar.projects") }
        return actions
    }

    /// Redraws when any workspace changes (title, pin, group, directory) or its
    /// agents change state. TabManager's own changes arrive through @ObservedObject.
    @MainActor
    final class Live: ObservableObject {
        @Published private(set) var revision = 0
        private var workspaceChanges: AnyCancellable?
        private let agentTasks = TaskBag()
        private var scheduled = false

        /// Cancels the agent watchers when the host goes away.
        private final class TaskBag {
            var tasks: [Task<Void, Never>] = []
            deinit { tasks.forEach { $0.cancel() } }
        }

        func watch(_ manager: TabManager) {
            let tabs = manager.tabs
            workspaceChanges = Publishers.MergeMany(tabs.map { $0.objectWillChange })
                .sink { [weak self] _ in self?.bump() }
            agentTasks.tasks.forEach { $0.cancel() }
            agentTasks.tasks = tabs.map { workspace in
                let changes = workspace.sidebarAgentRuntimeObservation.changes()
                return Task { @MainActor [weak self] in
                    for await _ in changes { self?.bump() }
                }
            }
        }

        /// objectWillChange fires before the value lands: redraw on the next turn, once.
        private func bump() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.revision &+= 1
            }
        }

    }
}

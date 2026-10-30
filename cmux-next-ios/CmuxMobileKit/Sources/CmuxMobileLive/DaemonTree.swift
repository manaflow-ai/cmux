import CmuxMobileModel
import Foundation

/// The cmux-tui `list-workspaces` tree (protocol v12) mapped to the app's
/// workspaces: Workspace → screens → panes → tabs, flattened per workspace.
public struct DaemonTree: Sendable {
    /// A tab's acpmux binding (`conversation.agent_session`).
    public struct AgentBinding: Hashable, Sendable {
        public var session: String?
        public var harness: String?
        public var host: String?
    }

    /// The workspaces the phone lists (Workspaces rows, search, counts).
    public var workspaces: [Workspace]
    /// The Mac's home workspace (`kind` "home"), never listed: the Mac shows it
    /// as its sidebar's Home item, not a workspace row. Its tabs stay in the
    /// tree (surfaces, agent bindings, markers) so an agent working there still
    /// reaches the Feed (`places`).
    public var homeWorkspaces: [Workspace] = []
    /// Agent tabs by app tab id.
    public var agentTabs: [String: AgentBinding]
    /// The daemon surface id behind each app tab id (`s<surface>`).
    public var surfaces: [String: Int]
    /// Each tab's working directory on the Mac, unabbreviated, when the daemon reports one.
    public var directories: [String: String] = [:]
    /// The pane a new tab of each workspace goes to: its active screen's
    /// active pane, else its first pane.
    public var panes: [String: Int] = [:]
    /// Each tab's pane and position in it (`move-tab`, a duplicate next to it).
    public var tabPlaces: [String: TabPlace] = [:]
    /// The Mac's own terminal (kind `pty`) each tab shows, by tab id: what
    /// `close-terminal` names when the phone closes the tab (T-TABS-08).
    public var terminals: [String: TerminalRef] = [:]

    public struct TerminalRef: Hashable, Sendable {
        public var id: String
        public var incarnation: String?
        /// The terminal's public id (`terminal_resource_id`, `term_…`): it
        /// stays when the daemon restarts and adopts the terminal, while `id`
        /// (its host id) does not. What `resolve-terminal` is asked with.
        public var resourceID: String?
    }

    /// The terminal to end with `tab`: its own `pty` terminal, unless another
    /// listed tab (any workspace) still shows it.
    public func terminalEndedByClosing(_ tab: String) -> TerminalRef? {
        terminalsEndedByClosing([tab]).first
    }

    /// The terminals to end when `tabs` close together (a tab group): each
    /// one's own `pty` terminal that no tab outside `tabs` still shows, once.
    public func terminalsEndedByClosing(_ tabs: [String]) -> [TerminalRef] {
        let closing = Set(tabs)
        var ended: [TerminalRef] = []
        for tab in tabs {
            guard let terminal = terminals[tab], !ended.contains(where: { $0.id == terminal.id }) else { continue }
            if terminals.contains(where: { !closing.contains($0.key) && $0.value.id == terminal.id }) { continue }
            ended.append(terminal)
        }
        return ended
    }
    /// Each workspace's numeric daemon id by app workspace id (`move-tab-to-workspace`).
    public var workspaceNumbers: [String: Int] = [:]
    /// Each tab group's pane (`tab_groups`), by group id.
    public var groupPanes: [String: Int] = [:]
    /// Every tab of each pane in the daemon's order, listed or not (`move-tab-group` indexes
    /// count them all): its group and whether it is pinned (the Mac's `TabGroupReorder` slots).
    public var paneSlots: [Int: [PaneSlot]] = [:]
    /// Panes of an agent chat dock (`dock.role` `agent_chat`): the Mac never splits one or
    /// moves a tab group into one (`ChatDockRules.isChatDock`), Home's pinned dock included.
    public var chatDockPanes: Set<Int> = []

    public struct PaneSlot: Hashable, Sendable {
        public var group: String?
        public var pinned: Bool
    }
    public var revision: Int?
    /// This session's registry id (`registry_id`): the session of the Mac's
    /// personal rows and layout refs.
    public var registryID: String?
    /// Workspaces the daemon flags pinned (the legacy `pinned` flag).
    public var legacyPinned: Set<String> = []

    public struct TabPlace: Hashable, Sendable {
        public var pane: Int
        public var index: Int
    }
    /// Each tab's retained notification marker (`Tab.notification`), by daemon surface.
    public var notificationMarkers: [Int: NotificationMarker] = [:]

    /// A tab's newest retained notification and whether the Mac still shows it unread.
    public struct NotificationMarker: Hashable, Sendable {
        public var notification: Int
        public var unread: Bool
    }

    /// The workspace kind of the Mac's home workspace (`workspace-kind-v1`).
    static let homeKind = "home"

    /// The app tab id for a daemon surface.
    public static func tabID(surface: Int) -> String { "s\(surface)" }

    /// Pins and sidebar places from the Mac's arrangement (nil: the daemon's
    /// order and pin flags).
    public mutating func apply(_ arrangement: SidebarArrangement?) {
        (arrangement ?? SidebarArrangement()).apply(to: &workspaces, registryID: registryID, legacyPinned: legacyPinned)
    }

    /// Parses a `list-workspaces` reply (`{"ok":true,"data":{...}}` or the bare data object).
    /// `previous` keeps activity times for workspaces it already knew.
    /// `activity` is when the phone last saw an event (agent state, title)
    /// for each surface: the daemon reports no activity times, so a
    /// workspace with no event since the phone connected has no known time
    /// (`hasActivityTime` false; `lastActivityAt` is then first sight).
    public init(reply: Data, macID: String, previous: [Workspace] = [], agents: AgentStates = AgentStates(),
                activity: [Int: Date] = [:], now: Date = Date()) throws {
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw DaemonReplyError(message: "list-workspaces reply is not an object")
        }
        if object["ok"] as? Bool == false {
            throw DaemonReplyError(message: object["error"] as? String ?? "list-workspaces failed", code: object["error_code"] as? String)
        }
        let data = object["data"] as? [String: Any] ?? object
        revision = data["workspace_revision"] as? Int
        registryID = data["registry_id"] as? String
        var legacyPinned: Set<String> = []
        var agentTabs: [String: AgentBinding] = [:]
        var surfaces: [String: Int] = [:]
        var directories: [String: String] = [:]
        var panes: [String: Int] = [:]
        var places: [String: TabPlace] = [:]
        var terminals: [String: TerminalRef] = [:]
        var markers: [Int: NotificationMarker] = [:]
        var numbers: [String: Int] = [:]
        var groupPanes: [String: Int] = [:]
        var paneSlots: [Int: [PaneSlot]] = [:]
        var chatDockPanes: Set<Int> = []
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Workspace] = []
        var home: [Workspace] = []
        for case let ws as [String: Any] in data["workspaces"] as? [Any] ?? [] {
            // The Mac's home workspace (`kind` "home", `workspace-kind-v1`) is what
            // its sidebar's Home item shows, not a workspace row (`SidebarMapping`
            // filters it the same way). The phone has its own Home tab, so it is
            // never a Workspaces row (`homeWorkspaces`). Matched by kind, never by
            // name: a renamed home stays out, a workspace named "Home" stays in.
            let isHome = ws["kind"] as? String == Self.homeKind
            let key = (ws["key"] as? String) ?? (ws["id"] as? Int).map { "w\($0)" } ?? UUID().uuidString
            if let number = ws["id"] as? Int { numbers[key] = number }
            var tabs: [WorkspaceTab] = []
            var activeTab: [String: Any]?
            var working = false
            var blocked = false
            var observed: Date?
            var focusOrder = 0
            var layoutScreens: [WorkspaceLayout.Screen] = []
            var screens: [MacScreen] = []
            for case let screen as [String: Any] in ws["screens"] as? [Any] ?? [] {
                let activePane = screen["active_pane"] as? Int
                if screen["active"] as? Bool == true, let activePane { panes[key] = activePane }
                chatDockPanes.formUnion(Self.chatDockPanes(screen))
                var screenPanes: [Int] = []
                var screenTabs: [String] = []
                var layoutPanes: [WorkspaceLayout.Pane] = []
                var deadPanes: Set<Int> = []
                for case let pane as [String: Any] in screen["panes"] as? [Any] ?? [] {
                    var paneTabIDs: [String] = []
                    var paneActiveTab: String?
                    focusOrder = max(focusOrder, pane["focused_at"] as? Int ?? 0)
                    if panes[key] == nil, let id = pane["id"] as? Int { panes[key] = id }
                    let paneTabs = pane["tabs"] as? [[String: Any]] ?? []
                    let groups = Self.groups(pane["tab_groups"])
                    if let paneID = pane["id"] as? Int {
                        for id in groups.keys { groupPanes[id] = paneID }
                        if pane["dead"] as? Bool != true { screenPanes.append(paneID) }
                        paneSlots[paneID] = paneTabs.map { PaneSlot(group: $0["group"] as? String, pinned: $0["pinned"] as? Bool == true) }
                    }
                    for (index, tab) in paneTabs.enumerated() {
                        // A dead tab is listed only when it is a terminal the Mac keeps (Restart
                        // Shell Here); other dead tabs are gone for the person.
                        guard let surface = tab["surface"] as? Int,
                              tab["dead"] as? Bool != true || tab["kind"] as? String == "pty" else { continue }
                        if screen["active"] as? Bool == true, pane["id"] as? Int == activePane, pane["active_tab"] as? Int == index {
                            activeTab = tab
                        }
                        let id = Self.tabID(surface: surface)
                        surfaces[id] = surface
                        if let paneID = pane["id"] as? Int { places[id] = TabPlace(pane: paneID, index: index) }
                        if tab["kind"] as? String == "pty", let terminal = tab["terminal_id"] as? String, !terminal.isEmpty {
                            terminals[id] = TerminalRef(id: terminal, incarnation: tab["terminal_incarnation"] as? String,
                                                        resourceID: tab["terminal_resource_id"] as? String)
                        }
                        if let marker = tab["notification"] as? [String: Any], let notification = marker["notification"] as? Int {
                            markers[surface] = NotificationMarker(notification: notification, unread: marker["unread"] as? Bool == true)
                        }
                        if let cwd = tab["cwd"] as? String, cwd.hasPrefix("/") { directories[id] = cwd }
                        // An ended shell runs no agent: a stale report must not mark the
                        // workspace working or waiting.
                        let state = tab["dead"] as? Bool == true ? nil : agents[surface]
                        if state?.state == "working" { working = true }
                        if state?.state == "blocked" { blocked = true }
                        // Activity: the Mac's last agent report, else what the phone saw (titles).
                        for seen in [activity[surface], state?.updatedAt].compactMap(\.self) { observed = max(observed ?? seen, seen) }
                        guard var mapped = Self.tab(tab, id: id, agent: state, pending: agents.pending,
                                                    waitingFor: agents.waitingFor, bindings: &agentTabs) else { continue }
                        if let pinned = tab["pinned"] as? Bool { mapped.pinned = pinned }
                        mapped.linkIDs = WorkspaceTab.LinkIDs(
                            tab: tab["tab_resource_id"] as? String, pane: pane["resource_id"] as? String,
                            isPaneSelected: pane["active_tab"] as? Int == index, harnessSession: state?.harnessSession)
                        if let group = tab["group"] as? String { mapped.group = groups[group] ?? WorkspaceTab.TabGroupRef(id: group) }
                        tabs.append(mapped)
                        screenTabs.append(id)
                        paneTabIDs.append(id)
                        if pane["active_tab"] as? Int == index { paneActiveTab = id }
                    }
                    if let paneID = pane["id"] as? Int {
                        if pane["dead"] as? Bool == true {
                            deadPanes.insert(paneID)
                        } else {
                            layoutPanes.append(WorkspaceLayout.Pane(
                                id: paneID, name: pane["name"] as? String ?? "", tabIDs: paneTabIDs, activeTabID: paneActiveTab,
                                isFocused: screen["active"] as? Bool == true && paneID == activePane,
                                isZoomed: paneID == screen["zoomed_pane"] as? Int, tabCount: paneTabs.count))
                        }
                    }
                }
                if let screenID = screen["id"] as? Int {
                    layoutScreens.append(WorkspaceLayout.Screen(
                        id: screenID, name: screen["name"] as? String ?? "", isActive: screen["active"] as? Bool == true,
                        panes: layoutPanes, root: Self.node(screen["layout"])?.removing(deadPanes),
                        columns: Self.columns(screen, without: deadPanes),
                        equalizable: Self.equalizable(screen).compactMap { $0.removing(deadPanes) }))
                }
                if let screenID = screen["id"] as? Int {
                    screens.append(MacScreen(id: screenID, name: screen["name"] as? String ?? "", isActive: screen["active"] as? Bool == true,
                                             activePane: activePane, panes: screenPanes, tabIDs: screenTabs))
                }
            }
            let source = activeTab ?? (ws["screens"] as? [[String: Any]])?.first.flatMap { ($0["panes"] as? [[String: Any]])?.first?["tabs"] as? [[String: Any]] }?.first
            let title = (ws["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (ws["name"] as? String) ?? "Workspace"
            // `#RRGGBB[AA]` or a palette name (`blue`), as the Mac stores it.
            let color = (ws["color"] as? String).flatMap { $0.hasPrefix("#") ? String($0.prefix(7)) : WorkspaceColor(stored: $0)?.rawValue }
            let unread = (ws["unread_count"] as? Int ?? 0) > 0 || ws["marked_unread"] as? Bool == true
            let old = previousByID[key]
            let pendingAgents = tabs.contains { tab in agentTabs[tab.id]?.session.flatMap { agents.pending[$0] } ?? false }
            let known = old.flatMap { $0.hasActivityTime ? $0.lastActivityAt : nil }
            let activityAt = [observed, known].compactMap(\.self).max()
            let activeTabID = (activeTab?["surface"] as? Int).map(Self.tabID(surface:)).flatMap { id in
                tabs.contains { $0.id == id } ? id : nil
            }
            if ws["pinned"] as? Bool == true { legacyPinned.insert(key) }
            var workspace = Workspace(
                id: key,
                macID: macID,
                title: title,
                directory: Self.abbreviated(source?["cwd"] as? String) ?? old?.directory ?? "",
                branch: source?["git_branch"] as? String,
                tabs: tabs,
                lastActivityAt: activityAt ?? old?.lastActivityAt ?? now,
                needsAttention: blocked || pendingAgents,
                isWorking: working,
                hasUnread: unread,
                colorHex: color,
                icon: ws["icon"] as? String,
                hasActivityTime: activityAt != nil,
                focusOrder: focusOrder,
                activeTabID: activeTabID
            )
            workspace.resourceID = ws["resource_id"] as? String
            workspace.isHome = isHome
            workspace.hasCustomTitle = (ws["title"] as? String).map { !$0.isEmpty && $0 != ws["name"] as? String } ?? false
            workspace.isPinned = legacyPinned.contains(key)
            workspace.layout = layoutScreens.isEmpty ? nil : WorkspaceLayout(screens: layoutScreens)
            workspace.screens = screens
            if isHome { home.append(workspace) } else { result.append(workspace) }
        }
        self.legacyPinned = legacyPinned
        workspaces = result
        homeWorkspaces = home
        self.agentTabs = agentTabs
        self.surfaces = surfaces
        self.directories = directories
        self.panes = panes
        self.tabPlaces = places
        self.terminals = terminals
        workspaceNumbers = numbers
        self.groupPanes = groupPanes
        self.paneSlots = paneSlots
        self.chatDockPanes = chatDockPanes
        notificationMarkers = markers
    }

    /// One node of a screen's split tree (`layout`: `leaf`, `split`, `stack`), nil when unreadable.
    static func node(_ value: Any?) -> WorkspaceLayout.Node? {
        guard let node = value as? [String: Any] else { return nil }
        switch node["type"] as? String {
        case "leaf":
            return (node["pane"] as? Int).map(WorkspaceLayout.Node.pane)
        case "split":
            guard let id = node["split"] as? Int, let axis = WorkspaceLayout.Axis(rawValue: node["dir"] as? String ?? ""),
                  let first = Self.node(node["a"]), let second = Self.node(node["b"]) else { return nil }
            return .split(id: id, axis: axis, ratio: (node["ratio"] as? NSNumber)?.doubleValue ?? 0.5, first: first, second: second)
        case "stack":
            let panes = node["panes"] as? [Int] ?? []
            guard !panes.isEmpty else { return nil }
            return .stack(panes, expanded: node["expanded"] as? Int ?? panes[0])
        default:
            return nil
        }
    }

    /// The trees Equalize Splits evens out on a screen, as the Mac's `equalizeSplits`: with
    /// viewport columns, each column's tree (each row's, for a column with rows, whose own
    /// `layout` is only their compat chain); else the screen's tree.
    static func equalizable(_ screen: [String: Any]) -> [WorkspaceLayout.Node] {
        guard let columns = screen["columns"] as? [[String: Any]], !columns.isEmpty else {
            return node(screen["layout"]).map { [$0] } ?? []
        }
        return columns.flatMap { column -> [WorkspaceLayout.Node] in
            if let rows = column["rows"] as? [[String: Any]], !rows.isEmpty { return rows.compactMap { node($0["layout"]) } }
            return node(column["layout"]).map { [$0] } ?? []
        }
    }

    /// A screen's viewport columns (`columns`), in order, with their widths, docks (edge and
    /// mode) and rows;
    /// empty when the screen is one split tree. A column whose panes are all dead is left out.
    static func columns(_ screen: [String: Any], without dead: Set<Int> = []) -> [WorkspaceLayout.Column] {
        (screen["columns"] as? [[String: Any]] ?? []).compactMap { column in
            let rows = (column["rows"] as? [[String: Any]] ?? []).compactMap { row -> WorkspaceLayout.Column.Row? in
                guard let root = node(row["layout"])?.removing(dead) else { return nil }
                return WorkspaceLayout.Column.Row(height: (row["height"] as? NSNumber)?.doubleValue ?? 1000, root: root)
            }
            let root = node(column["layout"])?.removing(dead)
            guard root != nil || !rows.isEmpty else { return nil }
            let dock = (column["dock"] as? [String: Any]).map { dock in
                // A dock without a known edge is a side dock (the daemon's default edge is right).
                WorkspaceLayout.Column.Dock(edge: WorkspaceLayout.Column.Dock.Edge(rawValue: dock["edge"] as? String ?? "") ?? .right,
                                            isOverlay: dock["mode"] as? String == "overlay")
            }
            return WorkspaceLayout.Column(width: (column["width"] as? NSNumber)?.doubleValue ?? 1, dock: dock, root: root, rows: rows)
        }
    }

    /// A pane's `tab_groups` (`tab-groups-v1`) by group id.
    static func groups(_ value: Any?) -> [String: WorkspaceTab.TabGroupRef] {
        var out: [String: WorkspaceTab.TabGroupRef] = [:]
        for case let group as [String: Any] in value as? [Any] ?? [] {
            guard let id = group["id"] as? String else { continue }
            let icon = (group["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            out[id] = WorkspaceTab.TabGroupRef(id: id, name: group["name"] as? String ?? "", color: group["color"] as? String ?? "grey",
                                               isSaved: group["saved_id"] is String, icon: icon,
                                               isCollapsed: group["collapsed"] as? Bool == true)
        }
        return out
    }

    /// The panes of a screen's agent chat docks (`columns[].dock`, role `agent_chat`), as the
    /// Mac's `ChatDockRules.isChatDock`: a pinned dock that takes tabs still never splits.
    static func chatDockPanes(_ screen: [String: Any]) -> Set<Int> {
        var out: Set<Int> = []
        for case let column as [String: Any] in screen["columns"] as? [Any] ?? [] {
            guard let dock = column["dock"] as? [String: Any], dock["role"] as? String == "agent_chat" else { continue }
            var trees: [Any] = [column["layout"] as Any]
            for case let row as [String: Any] in column["rows"] as? [Any] ?? [] { trees.append(row["layout"] as Any) }
            for tree in trees { out.formUnion(leaves(tree)) }
        }
        return out
    }

    /// The panes of a split tree (`leaf`, `split`, `stack`).
    static func leaves(_ value: Any?) -> [Int] {
        guard let node = value as? [String: Any] else { return [] }
        switch node["type"] as? String {
        case "leaf": return (node["pane"] as? Int).map { [$0] } ?? []
        case "split": return leaves(node["a"]) + leaves(node["b"])
        case "stack": return node["panes"] as? [Int] ?? []
        default: return []
        }
    }

    /// The Mac's Move Tab Group Left / Right index (`TabGroupReorder.targetIndex`): where the
    /// group goes in its pane's other tabs, past the neighboring tab or whole group; nil at the
    /// pane's edge or before a pinned tab.
    public static func tabGroupMoveIndex(of group: String, forward: Bool, in slots: [PaneSlot]) -> Int? {
        guard let start = slots.firstIndex(where: { $0.group == group }) else { return nil }
        let rest = slots.filter { $0.group != group }
        if forward {
            guard start < rest.count else { return nil }
            var end = start
            if let neighbor = rest[start].group {
                while end + 1 < rest.count, rest[end + 1].group == neighbor { end += 1 }
            }
            return end + 1
        }
        guard start > 0, !rest[start - 1].pinned else { return nil }
        var begin = start - 1
        if let neighbor = rest[begin].group {
            while begin > 0, rest[begin - 1].group == neighbor { begin -= 1 }
        }
        return begin
    }

    /// One daemon tab as an app tab, or nil for tabs the phone does not show (pages, conversations).
    /// `agent` is the surface's agent state; `pending` marks acpmux sessions
    /// with an open permission or question. Both set the tab's `agentStatus`.
    static func tab(_ tab: [String: Any], id: String, agent: AgentState?, pending: [String: Bool] = [:],
                    waitingFor: [String: WorkspaceTab.WaitingFor] = [:],
                    bindings: inout [String: AgentBinding]) -> WorkspaceTab? {
        var status: WorkspaceTab.AgentStatus? = switch agent?.state {
        case "blocked": .waiting
        case "working": .working
        default: nil
        }
        // Conversation tabs carry an `about:blank` placeholder title.
        let rawTitle = (tab["title"] as? String).flatMap { $0 == "about:blank" ? nil : $0 }
        let title = (tab["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rawTitle ?? ""
        switch tab["kind"] as? String {
        case "pty", "remote-terminal":
            let subtitle = Self.abbreviated(tab["cwd"] as? String)
            var terminal = WorkspaceTab(id: id, kind: .terminal, title: title.isEmpty ? "Terminal" : title, subtitle: subtitle,
                                        harness: agent?.agent, agentStatus: status)
            // Only the Mac's own terminals restart (`restart-tab`: kind pty).
            if tab["kind"] as? String == "pty", tab["dead"] as? Bool == true { terminal.shellEnded = true }
            return terminal
        case "browser":
            let url = (tab["url"] as? String).flatMap(URL.init(string:))
            return WorkspaceTab(id: id, kind: .browser, title: title.isEmpty ? (url?.host() ?? "Browser") : title, url: url)
        case "conversation" where (tab["conversation"] as? [String: Any])?["page"] as? String == "phone":
            // A Mac phone tab (`page: phone`, route `sim:<udid>`): its simulator streams like a browser tab.
            return WorkspaceTab(id: id, kind: .simulator, title: title.isEmpty ? "Simulator" : title)
        case "conversation":
            guard let session = (tab["conversation"] as? [String: Any])?["agent_session"] as? [String: Any] else { return nil }
            let binding = AgentBinding(session: session["session"] as? String, harness: session["harness"] as? String, host: session["host"] as? String)
            bindings[id] = binding
            var asks: WorkspaceTab.WaitingFor?
            if let session = binding.session, pending[session] == true {
                status = .waiting
                asks = waitingFor[session]
            }
            let harness = binding.harness ?? "agent"
            return WorkspaceTab(id: id, kind: .agent, title: title.isEmpty ? Self.agentName(harness) : title,
                                subtitle: binding.session == nil ? "New chat" : nil, harness: harness, agentStatus: status,
                                waitingFor: status == .waiting ? asks : nil)
        default:
            return nil
        }
    }

    static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }

    /// `~/` for paths under a home directory (`/Users/<name>/`).
    static func abbreviated(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[1] == "Users" || parts[1] == "home" {
            let rest = parts.dropFirst(3).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/\(rest)"
        }
        return path
    }
}

/// Agent status per daemon surface (`list-agents`, `agent-changed`) plus
/// acpmux sessions with open permissions.
public struct AgentStates: Sendable {
    public var bySurface: [Int: AgentState] = [:]
    /// acpmux session id → has a pending permission or question.
    public var pending: [String: Bool] = [:]
    /// acpmux session id → what its open ask is, when the phone has seen it
    /// (a question wins over a permission). Absent: "is waiting".
    public var waitingFor: [String: WorkspaceTab.WaitingFor] = [:]

    public init() {}

    public subscript(surface: Int) -> AgentState? { bySurface[surface] }
}

public struct AgentState: Hashable, Sendable {
    public var state: String
    public var agent: String?
    /// The Mac's last report for this agent (`updated_at_ms`), when it sends one.
    public var updatedAt: Date?
    /// The harness's own session id (`agent_session_id`): what an
    /// `agent/<harness>/<session>` link names (CmuxLink).
    public var harnessSession: String?

    public init(state: String, agent: String?, updatedAt: Date? = nil, harnessSession: String? = nil) {
        self.state = state
        self.agent = agent
        self.updatedAt = updatedAt
        self.harnessSession = harnessSession
    }

    /// An agent row of `list-agents` or an `agent-changed` event.
    public init?(json: [String: Any]) {
        guard json["surface"] is Int else { return nil }
        self.init(state: json["state"] as? String ?? "unknown", agent: json["agent"] as? String,
                  updatedAt: Self.date(json["updated_at_ms"]), harnessSession: Self.session(json["agent_session_id"]))
    }

    /// A non-empty `agent_session_id`.
    static func session(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Epoch milliseconds (`updated_at_ms`) as a date; nil when absent (older Macs).
    static func date(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

public struct DaemonReplyError: Error, Equatable, Sendable {
    public var message: String
    public var code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

/// A daemon `notification` event's fields the Feed uses. The ledger
/// (`list-notifications`) keeps only the title and body; a terminal agent's
/// prompt and whole answer (or error text) ride on the live event alone,
/// memory only on the Mac, and `id` joins them to the ledger row.
public struct NotificationPost: Equatable, Sendable {
    /// The ledger row's id; nil from a Mac before `id` rode on the event.
    public var id: String?
    public var surface: Int?
    public var source: String?
    /// The prompt of the agent turn this event ends (markdown).
    public var prompt: String?
    /// The agent's whole last message, or a failed turn's error text (markdown).
    public var message: String?
    /// The banner's folded cut of `message`; an older Mac sends only this.
    public var preview: String?
    /// The posting agent's own session id: a Feed reply goes only to that session.
    public var session: String?

    public init(id: String? = nil, surface: Int? = nil, source: String? = nil, prompt: String? = nil,
                message: String? = nil, preview: String? = nil, session: String? = nil) {
        self.id = id
        self.surface = surface
        self.source = source
        self.prompt = prompt
        self.message = message
        self.preview = preview
        self.session = session
    }

    init(json: [String: Any]) {
        func text(_ key: String) -> String? {
            (json[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        self.init(id: text("id"), surface: json["surface"] as? Int, source: text("source"), prompt: text("prompt"),
                  message: text("message"), preview: text("preview"), session: text("session"))
    }
}

/// What a daemon event line means for the phone's copy of the tree.
public enum DaemonEvent: Equatable, Sendable {
    /// A typed tree delta. The payload keeps the daemon's entity as JSON so
    /// the mobile projection can patch its off-main-thread snapshot without
    /// introducing a second copy of the daemon's Codable tree types.
    case delta(DaemonTreeDelta)
    /// Re-list the tree (any topology/metadata delta, `tree-changed`, focus,
    /// the person's sidebar order `personal-changed`).
    case treeChanged
    /// The subscription ended (`overflow`): subscribe again, then re-list.
    case resubscribe
    case agentChanged(surface: Int, state: String, agent: String?, updatedAt: Date? = nil, harnessSession: String? = nil)
    case titleChanged(surface: Int, title: String)
    /// A notification was posted (`notification`): the tree's markers and the
    /// notification ledger changed. It carries the agent's memory-only texts.
    case notification(NotificationPost)
    case other

    public static func parse(_ line: Data) -> DaemonEvent {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return .other }
        switch event {
        case "overflow":
            return .resubscribe
        case "agent-changed":
            guard let surface = object["surface"] as? Int else { return .other }
            return .agentChanged(surface: surface, state: object["state"] as? String ?? "unknown", agent: object["agent"] as? String,
                                 updatedAt: AgentState.date(object["updated_at_ms"]),
                                 harnessSession: AgentState.session(object["agent_session_id"]))
        case "title-changed":
            guard let surface = object["surface"] as? Int else { return .other }
            return .titleChanged(surface: surface, title: object["title"] as? String ?? "")
        case "notification":
            return .notification(NotificationPost(json: object))
        case "workspace-added", "workspace-closed", "workspace-renamed", "workspace-moved", "workspace-changed",
             "screen-added", "screen-closed", "screen-renamed", "screen-changed",
             "pane-added", "pane-closed", "tab-added", "tab-closed", "tab-renamed", "tab-changed":
            // Older daemon builds announce the delta kind but do not carry an
            // entity. A typed patch would be unsafe, so retain the reconnect
            // recovery path for those producers.
            let delta = DaemonTreeDelta(event: event, object: object)
            return delta.entity != nil || delta.kind.isClose ? .delta(delta) : .treeChanged
        case "tree-changed", "layout-changed", "surface-exited", "personal-changed":
            return .treeChanged
        default:
            let prefixes = ["workspace-", "screen-", "pane-", "tab-"]
            return prefixes.contains(where: event.hasPrefix) ? .treeChanged : .other
        }
    }
}

/// The wire shape of one `tree_events: "deltas"` event. `entity` is retained
/// as JSON because the iOS tree model intentionally differs from the daemon's
/// full snapshot model. Data is Sendable and lets the projection decode only
/// the affected workspace off the main actor.
public struct DaemonTreeDelta: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case workspaceAdded = "workspace-added"
        case workspaceClosed = "workspace-closed"
        case workspaceRenamed = "workspace-renamed"
        case workspaceMoved = "workspace-moved"
        case workspaceChanged = "workspace-changed"
        case screenAdded = "screen-added"
        case screenClosed = "screen-closed"
        case screenRenamed = "screen-renamed"
        case screenChanged = "screen-changed"
        case paneAdded = "pane-added"
        case paneClosed = "pane-closed"
        case tabAdded = "tab-added"
        case tabClosed = "tab-closed"
        case tabRenamed = "tab-renamed"
        case tabChanged = "tab-changed"

        var isWorkspace: Bool { rawValue.hasPrefix("workspace-") }
        var isAdd: Bool { rawValue.hasSuffix("-added") }
        var isClose: Bool { rawValue.hasSuffix("-closed") }
    }

    public var kind: Kind
    /// Numeric daemon handles. Older daemons may send a resource/key string;
    /// `workspaceKey` preserves that form for matching the raw snapshot.
    public var workspace: Int?
    public var workspaceKey: String?
    public var screen: Int?
    public var pane: Int?
    public var surface: Int?
    public var index: Int?
    public var entity: Data?
    public var workspaceRevision: Int?
    public var registryID: String?

    public init(kind: Kind, workspace: Int? = nil, workspaceKey: String? = nil, screen: Int? = nil,
                pane: Int? = nil, surface: Int? = nil, index: Int? = nil, entity: Data? = nil,
                workspaceRevision: Int? = nil, registryID: String? = nil) {
        self.kind = kind
        self.workspace = workspace
        self.workspaceKey = workspaceKey
        self.screen = screen
        self.pane = pane
        self.surface = surface
        self.index = index
        self.entity = entity
        self.workspaceRevision = workspaceRevision
        self.registryID = registryID
    }

    init(event: String, object: [String: Any]) {
        self.kind = Kind(rawValue: event) ?? .workspaceChanged
        self.workspace = object["workspace"] as? Int
        self.workspaceKey = object["workspace"] as? String
        self.screen = object["screen"] as? Int
        self.pane = object["pane"] as? Int
        self.surface = object["surface"] as? Int
        self.index = object["index"] as? Int
        self.workspaceRevision = object["workspace_revision"] as? Int
        self.registryID = object["registry_id"] as? String
        if let entity = object["entity"], JSONSerialization.isValidJSONObject(entity),
           let data = try? JSONSerialization.data(withJSONObject: entity) {
            self.entity = data
        } else {
            self.entity = nil
        }
    }
}

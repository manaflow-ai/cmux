import CmuxMobileModel
import Foundation

/// What a workspace row says about its workspace, highest priority first
/// (SPEC 11.1 status rules).
public enum WorkspaceStatus: Int, Comparable, Hashable, Sendable {
    /// Being created on its Mac (optimistic row).
    case creating
    /// Its Mac is offline: the agent state is stale and not shown.
    case offline
    /// An agent waits for a permission or an answer.
    case needsYou
    case working
    /// Something new arrived (the Mac's unread flags) since this device last opened it.
    case done
    case idle

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// `seenAt`: when this device last opened the workspace. "Done" stays
    /// cleared until the workspace has newer activity.
    public init(_ workspace: Workspace, isOnline: Bool, isPending: Bool = false, seenAt: Date? = nil) {
        if isPending { self = .creating }
        else if !isOnline { self = .offline }
        else if workspace.needsAttention { self = .needsYou }
        else if workspace.isWorking { self = .working }
        else if workspace.hasUnread, seenAt.map({ $0 < workspace.lastActivityAt }) ?? true { self = .done }
        else { self = .idle }
    }
}

extension Workspace {
    /// The agent tab a status line is about: the waiting tab for needs-you,
    /// the working tab for working, else the first agent tab. Falls back to
    /// the first agent tab while the Mac reports no per-tab state.
    public func agentTab(for status: WorkspaceStatus) -> WorkspaceTab? {
        let wanted: WorkspaceTab.AgentStatus? = switch status {
        case .needsYou: .waiting
        case .working: .working
        default: nil
        }
        if let wanted, let tab = tabs.first(where: { $0.agentStatus == wanted }) { return tab }
        return tabs.first(where: \.isAgent)
    }

    /// "feat-cmux-next-ios", else the directory.
    public var place: String { branch ?? directory }
}

/// A run of `WorkspaceInbox.recent`: loose rows, or one Mac workspace group's
/// members under its header.
public struct RecentSection: Hashable, Sendable, Identifiable {
    public var macID: String
    /// Nil: loose rows.
    public var group: MacWorkspaceGroup?
    public var workspaces: [Workspace]

    public var id: String {
        // A group can show as two runs for a moment (a row moved in before the Mac's order
        // arrives): the first row keeps each run's id unique.
        group.map { "group-\(macID)-\($0.id)-\(workspaces.first?.id ?? "")" } ?? "loose-\(macID)-\(workspaces.first?.id ?? "")"
    }

    /// Consecutive rows of one Mac and one group make one section.
    static func runs(_ rows: [Workspace]) -> [RecentSection] {
        var sections: [RecentSection] = []
        for ws in rows {
            if let last = sections.last, last.macID == ws.macID, last.group?.id == ws.group?.id {
                sections[sections.count - 1].workspaces.append(ws)
            } else {
                sections.append(RecentSection(macID: ws.macID, group: ws.group, workspaces: [ws]))
            }
        }
        return sections
    }
}

/// The Workspaces list for a Mac filter and a search (SPEC 11.1, the
/// "Inbox"): Needs You first, then Recent, then one folded line per Mac
/// whose list is not live (offline, or online but not linked).
public struct WorkspaceInbox: Hashable, Sendable {
    /// A Mac whose workspaces are folded into one line.
    public struct Fold: Hashable, Sendable, Identifiable {
        public enum Reason: Hashable, Sendable {
            /// The Mac is offline; its rows expand in place.
            case offline
            /// Online, but this phone is linked to another Mac, so its list
            /// is not known (live mode). A tap links it.
            case notConnected
            /// Online, nothing known, and the last dial failed (live). A tap retries.
            case failed(String)
        }

        public var mac: MacDevice
        public var reason: Reason
        /// Newest first; empty for `.notConnected` and `.failed` (not known).
        public var workspaces: [Workspace]
        /// Rows always shown (filtered to this Mac, a search, or every Mac asleep).
        public var isForcedOpen: Bool
        public var id: String { mac.id }
    }

    /// How far one online Mac's list can be trusted, from its live data
    /// phase (`MacDataMachine`).
    public enum ListState: Hashable, Sendable {
        /// The Mac's own list on the current link (always, in mock mode).
        case live
        /// Dialing, nothing known yet.
        case loading
        /// Last-known rows; `updating` while the link is connecting.
        case cached(updating: Bool)
        /// Nothing known and the last dial failed.
        case failed(String)
        /// Nothing known and nothing dialing this Mac.
        case notConnected

        public init(_ phase: MacDataMachine.Phase) {
            switch phase {
            case .live, .empty: self = .live
            case .loading: self = .loading
            case .cached(let link): self = .cached(updating: link == .connecting)
            case .failed(let reason): self = .failed(reason)
            case .idle, .offline: self = .notConnected
            }
        }
    }

    /// What the phone sees of the store, for the layout.
    public struct Context: Equatable, Sendable {
        public var pending: Set<String>
        public var seenAt: [String: Date]
        /// Live mode: each Mac's data phase. Nil (mock) treats every list as live.
        public var phases: [String: MacDataMachine.Phase]?

        public init(pending: Set<String> = [], seenAt: [String: Date] = [:], phases: [String: MacDataMachine.Phase]? = nil) {
            self.pending = pending
            self.seenAt = seenAt
            self.phases = phases
        }

        func listState(_ macID: String) -> ListState {
            guard let phases else { return .live }
            return ListState(phases[macID] ?? .idle)
        }
    }

    public var scope: MacScope
    public var needsYou: [Workspace]
    /// Pinned on the Mac (its pinned section), in its pin order.
    public var pinned: [Workspace]
    /// The rest: in the Mac's sidebar order when the phone knows it, else newest first.
    public var recent: [Workspace]
    /// `recent` follows the Mac's sidebar order (a live Mac told it).
    public var isMacOrder: Bool
    /// `recent` in runs as the Mac's sidebar shows them: loose workspaces, and
    /// each workspace group of a Mac under its header (in the Mac's order).
    public var recentSections: [RecentSection]
    public var folds: [Fold]
    public var statuses: [String: WorkspaceStatus]
    /// Recent mixes several Macs, so idle rows name their Mac.
    public var showsMacNames: Bool
    /// A Mac in scope is linking, and there is nothing (cached) to show yet.
    public var isLoading: Bool
    /// An online Mac in scope is linking and its list has not arrived (cached rows may show).
    public var isUpdating: Bool
    /// Rows from a Mac's last-known list (not the Mac's live answer): dimmed,
    /// and their agent state is not shown (it may be stale).
    public var stale: Set<String>
    /// Scope is All and every Mac is offline.
    public var allAsleep: Bool

    public init(scope: MacScope, macs: [MacDevice], workspaces: [Workspace], query: String = "",
                context: Context = Context()) {
        let scope = MacFilter.resolve(scope, macs: macs)
        self.scope = scope
        let scoped = macs.filter { scope.macID == nil || $0.id == scope.macID }
        let byID = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = Set(scoped.map(\.id))
        let order = Dictionary(workspaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matching = workspaces.filter { ws in
            chosen.contains(ws.macID) && Self.matches(ws, macName: byID[ws.macID]?.name, query)
        }
        var statuses: [String: WorkspaceStatus] = [:]
        var stale: Set<String> = []
        for ws in matching {
            let online = byID[ws.macID]?.isOnline ?? false
            let pending = context.pending.contains(ws.id)
            if online, !pending, case .cached = context.listState(ws.macID) {
                // Last-known rows: never claim an agent is waiting or working now.
                stale.insert(ws.id)
                statuses[ws.id] = .idle
                continue
            }
            statuses[ws.id] = WorkspaceStatus(ws, isOnline: online, isPending: pending, seenAt: context.seenAt[ws.id])
        }
        self.stale = stale
        func sorted(_ list: [Workspace]) -> [Workspace] {
            list.sorted { Self.isNewer($0, $1, order: order) }
        }
        let live = matching.filter { ws in
            guard let mac = byID[ws.macID], mac.isOnline else { return false }
            switch context.listState(mac.id) {
            case .live, .cached: return true
            case .loading, .failed, .notConnected: return context.pending.contains(ws.id)
            }
        }
        needsYou = sorted(live.filter { statuses[$0.id] == .needsYou })
        pinned = live.filter { statuses[$0.id] != .needsYou && $0.isPinned }
            .sorted { ($0.pinIndex ?? .max, order[$0.id] ?? 0) < ($1.pinIndex ?? .max, order[$1.id] ?? 0) }
        recent = sorted(live.filter { statuses[$0.id] != .needsYou && !$0.isPinned })
        isMacOrder = recent.contains { $0.sidebarIndex != nil }
        // Newest first (no Mac order known) shows no groups: its rows are not in runs.
        recentSections = isMacOrder ? RecentSection.runs(recent)
            : recent.isEmpty ? [] : [RecentSection(macID: "", group: nil, workspaces: recent)]
        let online = scoped.filter(\.isOnline)
        let asleep = scope == .all && !scoped.isEmpty && online.isEmpty
        allAsleep = asleep
        let searching = !query.isEmpty
        let folds = scoped.compactMap { mac -> Fold? in
            if !mac.isOnline {
                let rows = sorted(matching.filter { $0.macID == mac.id })
                guard !rows.isEmpty else { return nil }
                return Fold(mac: mac, reason: .offline, workspaces: rows,
                            isForcedOpen: scope.macID != nil || searching || asleep)
            }
            guard !searching, scope.macID == nil else { return nil }
            // A fold for the one Mac a filter shows is its empty state, not a line.
            switch context.listState(mac.id) {
            case .notConnected: return Fold(mac: mac, reason: .notConnected, workspaces: [], isForcedOpen: false)
            case .failed(let reason): return Fold(mac: mac, reason: .failed(reason), workspaces: [], isForcedOpen: false)
            case .live, .loading, .cached: return nil
            }
        }
        self.folds = folds
        isUpdating = online.contains { mac in
            switch context.listState(mac.id) {
            case .loading, .cached(updating: true): return true
            default: return false
            }
        }
        isLoading = isUpdating && needsYou.isEmpty && pinned.isEmpty && recent.isEmpty && !searching
        showsMacNames = scope == .all && Set(recent.map(\.macID)).count > 1
        self.statuses = statuses
    }

    /// Newest activity first. A row with no known activity time (live: no
    /// event since the phone connected) goes after every row with one, in
    /// the Mac's focus order, then the Mac's own order.
    /// Rows whose Mac told its sidebar order come first, Mac by Mac in that
    /// order (never interleaved across Macs); the rest newest activity first.
    static func isNewer(_ a: Workspace, _ b: Workspace, order: [String: Int]) -> Bool {
        switch (a.sidebarIndex, b.sidebarIndex) {
        case let (x?, y?): return (a.macID, x) == (b.macID, y) ? (order[a.id] ?? 0) < (order[b.id] ?? 0) : (a.macID, x) < (b.macID, y)
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): break
        }
        if a.hasActivityTime != b.hasActivityTime { return a.hasActivityTime }
        if a.hasActivityTime, a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
        if a.focusOrder != b.focusOrder { return a.focusOrder > b.focusOrder }
        return (order[a.id] ?? 0) < (order[b.id] ?? 0)
    }

    /// Search matches the name, branch, directory, Mac name and agent tabs' titles.
    static func matches(_ workspace: Workspace, macName: String?, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var fields = [workspace.title, workspace.branch ?? "", workspace.directory, macName ?? ""]
        for tab in workspace.tabs where tab.isAgent {
            fields.append(tab.title)
            if let task = tab.task { fields.append(task) }
        }
        return fields.contains { $0.localizedStandardContains(query) }
    }

    public var isEmpty: Bool { needsYou.isEmpty && pinned.isEmpty && recent.isEmpty && folds.isEmpty }

    /// The rows Move Up / Down moves among: the unpinned rows of the workspace's
    /// Mac, in its order. None for a pinned workspace: the Mac orders its pinned
    /// tiles with a layout move a phone may not send.
    public func macOrder(of workspace: Workspace) -> [Workspace] {
        guard !workspace.isPinned else { return [] }
        // Within its own group (or among the loose rows): Move Up / Down never changes the group.
        return recent.filter { $0.macID == workspace.macID && $0.group?.id == workspace.group?.id && status($0) != .needsYou }
    }

    /// One Mac's live rows as its sidebar shows them (pinned first, then the
    /// rest in its order), for Close Other / Above / Below.
    public func macSidebar(_ macID: String) -> [Workspace] {
        (needsYou + pinned + recent).filter { $0.macID == macID && status($0) != .creating }
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                if a.isPinned { return (a.pinIndex ?? .max) < (b.pinIndex ?? .max) }
                return Self.isNewer(a, b, order: [:])
            }
    }

    public func status(_ workspace: Workspace) -> WorkspaceStatus { statuses[workspace.id] ?? .idle }

    /// "2 need you", for the navigation subtitle.
    public var needsYouCount: Int { needsYou.count }
}

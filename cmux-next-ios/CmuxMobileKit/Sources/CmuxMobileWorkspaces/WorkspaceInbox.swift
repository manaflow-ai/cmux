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
    /// The run's Mac and group, and which run of them it is: never its first row,
    /// so a section keeps its identity (and its rows) when another row moves to
    /// its top. A group can show as two runs for a moment (a row moved in before
    /// the Mac's order arrives): the run's ordinal keeps each id unique.
    public var id: String

    public init(macID: String, group: MacWorkspaceGroup?, workspaces: [Workspace], ordinal: Int = 0) {
        self.macID = macID
        self.group = group
        self.workspaces = workspaces
        id = group.map { "group-\(macID)-\($0.id)-\(ordinal)" } ?? "loose-\(macID)-\(ordinal)"
    }

    /// Consecutive rows of one Mac and one group make one section.
    static func runs(_ rows: [Workspace]) -> [RecentSection] {
        var sections: [RecentSection] = []
        var ordinals: [String: Int] = [:]
        for ws in rows {
            if let last = sections.last, last.macID == ws.macID, last.group?.id == ws.group?.id {
                sections[sections.count - 1].workspaces.append(ws)
            } else {
                let key = "\(ws.macID)\u{1F}\(ws.group?.id ?? "")"
                let ordinal = ordinals[key, default: 0]
                ordinals[key] = ordinal + 1
                sections.append(RecentSection(macID: ws.macID, group: ws.group, workspaces: [ws], ordinal: ordinal))
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
    /// Every listed row by id (rows, pinned, needs-you and folded): the row
    /// menu finds its workspace without scanning the list.
    var rowsByID: [String: Workspace]
    /// The Macs with rows in Needs You, Pinned or Recent.
    public var rowMacIDs: Set<String>
    /// Each Mac and group's Move Up / Down run (`macOrder(of:)`): its size and ends.
    var moveRuns: [MoveRunKey: MoveRun]

    struct MoveRunKey: Hashable, Sendable {
        var macID: String
        var groupID: String?
    }

    struct MoveRun: Hashable, Sendable {
        var count: Int
        var firstID: String
        var lastID: String
    }

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
            Self.newestFirst(list, order: order)
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
        var runs: [MoveRunKey: MoveRun] = [:]
        for ws in recent where statuses[ws.id] != .needsYou {
            let key = MoveRunKey(macID: ws.macID, groupID: ws.group?.id)
            if var run = runs[key] {
                run.count += 1
                run.lastID = ws.id
                runs[key] = run
            } else {
                runs[key] = MoveRun(count: 1, firstID: ws.id, lastID: ws.id)
            }
        }
        moveRuns = runs
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
        var rowIndex: [String: Workspace] = [:]
        rowIndex.reserveCapacity(matching.count)
        for ws in needsYou + pinned + recent { rowIndex[ws.id] = ws }
        for fold in folds { for ws in fold.workspaces { rowIndex[ws.id] = ws } }
        rowsByID = rowIndex
        rowMacIDs = Set((needsYou + pinned + recent).map(\.macID))
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

    /// `list` in `isNewer` order, with each row's keys read once (the
    /// comparator looked up two ids per comparison: most of a 500-row inbox).
    static func newestFirst(_ list: [Workspace], order: [String: Int]) -> [Workspace] {
        struct Key {
            var sidebar: Int?
            var macID: String
            var hasTime: Bool
            var time: Date
            var focus: Int
            var index: Int
        }
        func newer(_ a: Key, _ b: Key) -> Bool {
            switch (a.sidebar, b.sidebar) {
            case let (x?, y?): return (a.macID, x) == (b.macID, y) ? a.index < b.index : (a.macID, x) < (b.macID, y)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            if a.hasTime != b.hasTime { return a.hasTime }
            if a.hasTime, a.time != b.time { return a.time > b.time }
            if a.focus != b.focus { return a.focus > b.focus }
            return a.index < b.index
        }
        var keyed = list.enumerated().map { offset, ws in
            (key: Key(sidebar: ws.sidebarIndex, macID: ws.macID, hasTime: ws.hasActivityTime, time: ws.lastActivityAt,
                      focus: ws.focusOrder, index: order[ws.id] ?? 0), offset: offset)
        }
        keyed.sort { newer($0.key, $1.key) }
        return keyed.map { list[$0.offset] }
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

    /// A listed row by id.
    public func workspace(_ id: String) -> Workspace? { rowsByID[id] }

    /// Whether Move Workspace Up / Down apply (`macOrder(of:)` has another row
    /// before / after it), from the precomputed runs: O(1) per row.
    public func moves(of workspace: Workspace) -> (up: Bool, down: Bool) {
        guard !workspace.isPinned, let run = moveRuns[MoveRunKey(macID: workspace.macID, groupID: workspace.group?.id)],
              run.count > 1 else { return (false, false) }
        return (run.firstID != workspace.id, run.lastID != workspace.id)
    }

    /// "2 need you", for the navigation subtitle.
    public var needsYouCount: Int { needsYou.count }
}

extension WorkspaceInbox {
    /// One inbox per change of its inputs: the list's body reads it several
    /// times per pass (rows, subtitle, refresh state, animations), and a pass
    /// that changed nothing it reads (a sheet, the search field) builds nothing.
    /// The equality check is cheap when nothing changed: an unchanged array
    /// compares by its storage.
    public final class Memo {
        public struct Input: Equatable {
            public var scope: MacScope
            public var macs: [MacDevice]
            public var workspaces: [Workspace]
            /// The store's revision of `workspaces` (`AppStore.workspacesRevision`):
            /// when both inputs carry one, it stands in for comparing every workspace.
            public var workspacesRevision: Int?
            public var query: String
            public var context: Context

            public init(scope: MacScope, macs: [MacDevice], workspaces: [Workspace], workspacesRevision: Int? = nil,
                        query: String = "", context: Context = Context()) {
                self.scope = scope
                self.macs = macs
                self.workspaces = workspaces
                self.workspacesRevision = workspacesRevision
                self.query = query
                self.context = context
            }

            public static func == (a: Self, b: Self) -> Bool {
                guard a.scope == b.scope, a.query == b.query, a.macs == b.macs, a.context == b.context else { return false }
                if let x = a.workspacesRevision, let y = b.workspacesRevision { return x == y }
                return a.workspaces == b.workspaces
            }
        }

        private var last: (input: Input, inbox: WorkspaceInbox)?
        private var lastIDs: [String] = []
        private var lastIDSet: Set<String> = []
        private var lastNeedsYou: [String] = []
        /// How many inboxes this memo built (tests).
        public private(set) var builds = 0
        /// Changes when rows come or go (the store's set of workspace ids), not
        /// when they only reorder or a row's content changes: the list animates
        /// on it, and a live reorder moves rows in place without animating.
        public private(set) var workspaceIDsKey = 0
        /// Changes when the Needs You rows change.
        public private(set) var needsYouKey = 0

        public init() {}

        public func inbox(_ input: Input) -> WorkspaceInbox {
            if let last, last.input == input { return last.inbox }
            let inbox = WorkspaceInbox(scope: input.scope, macs: input.macs, workspaces: input.workspaces, query: input.query,
                                       context: input.context)
            builds += 1
            if lastIDs.count != input.workspaces.count
                || !zip(lastIDs, input.workspaces).allSatisfy({ $0 == $1.id }) {
                lastIDs = input.workspaces.map(\.id)
                let idSet = Set(lastIDs)
                if idSet != lastIDSet {
                    lastIDSet = idSet
                    workspaceIDsKey &+= 1
                }
            }
            let needsYou = inbox.needsYou.map(\.id)
            if needsYou != lastNeedsYou {
                lastNeedsYou = needsYou
                needsYouKey &+= 1
            }
            last = (input, inbox)
            return inbox
        }
    }
}

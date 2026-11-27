import CmuxNextDesign
public import Foundation
public import Observation

/// A workspace row's pull requests in the session tree (`sidebar.sessionTree`, Claude desktop's
/// Code tab): how many, and the one color that says where they stand.
public nonisolated struct SidebarPullRequestBadge: Hashable, Sendable {
    public nonisolated enum Status: Int, Hashable, Sendable, Comparable {
        /// Every one merged: purple.
        case merged
        /// Open, and its checks pass or still run: green.
        case passing
        /// A draft or a conflict: orange.
        case attention
        /// A failed check: red. It wins over the others.
        case failing

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var count: Int
    public var status: Status
    /// Each pull request, newest first, for the badge's hover card (`SidebarPullRequestCard`);
    /// closed ones too, though the count and color leave them out.
    public var items: [SidebarPullRequestItem]

    public init(count: Int, status: Status, items: [SidebarPullRequestItem] = []) {
        self.count = count
        self.status = status
        self.items = items
    }

    /// One badge for several pull requests: their count, in the most urgent one's color.
    public static func combining(_ statuses: [Status]) -> SidebarPullRequestBadge? {
        guard let worst = statuses.max() else { return nil }
        return SidebarPullRequestBadge(count: statuses.count, status: worst)
    }

    /// One badge for `items`: the open and merged ones' count and most urgent color, and every
    /// item newest first; nil when none is open or merged and the card would be empty.
    public static func combining(items: [SidebarPullRequestItem]) -> SidebarPullRequestBadge? {
        guard var badge = combining(items.compactMap(\.state.badgeStatus)) else { return nil }
        badge.items = items.sorted { ($0.createdAt, $0.number, $0.url) > ($1.createdAt, $1.number, $1.url) }
        return badge
    }
}

/// One pull request in the badge's hover card: its title, where it stands, where it lives and its
/// size. The card lists them newest first; a click opens `url`. Codable for the native gallery's
/// fixtures (`sidebar.pull-request-card`).
public nonisolated struct SidebarPullRequestItem: Hashable, Sendable, Codable {
    /// Where it stands, as the card's pill says it.
    public nonisolated enum State: String, Hashable, Sendable, CaseIterable, Codable {
        case conflict, failing, passing, draft, merged, closed

        /// Its part in the row's badge; nil for a closed one, which the badge leaves out.
        public var badgeStatus: SidebarPullRequestBadge.Status? {
            switch self {
            case .conflict, .draft: .attention
            case .failing: .failing
            case .passing: .passing
            case .merged: .merged
            case .closed: nil
            }
        }
    }

    /// Always https.
    public var url: String
    /// `owner/repo`.
    public var repository: String
    public var number: Int
    public var title: String
    public var state: State
    public var additions: Int
    public var deletions: Int
    /// GitHub's ISO 8601 text, which sorts by time; empty when unknown.
    public var createdAt: String

    public init(url: String, repository: String, number: Int, title: String, state: State, additions: Int = 0,
                deletions: Int = 0, createdAt: String = "") {
        self.url = url
        self.repository = repository
        self.number = number
        self.title = title
        self.state = state
        self.additions = additions
        self.deletions = deletions
        self.createdAt = createdAt
    }

    /// A pull request page the card may open: `https://github.com/<owner>/<repo>/pull/<n>`, or the
    /// same on `enterpriseHost` (the user's `GH_HOST`). Anything else the summary carried (a peer's,
    /// a harness's) is never opened.
    public func isOpenable(enterpriseHost: String? = ProcessInfo.processInfo.environment["GH_HOST"]) -> Bool {
        guard let parts = URLComponents(string: url), parts.scheme == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              host == "github.com" || (enterpriseHost.map { !$0.isEmpty && host == $0.lowercased() } ?? false)
        else { return false }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        let plain = { (s: Substring) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
        return path.count == 5 && path[0].isEmpty && plain(path[1]) && plain(path[2]) && path[3] == "pull"
            && !path[4].isEmpty && path[4].allSatisfy(\.isASCII) && path[4].allSatisfy(\.isNumber)
    }

    /// `owner/repo` of a `https://<host>/owner/repo/pull/N` URL; empty for another.
    public static func repository(of url: String) -> String {
        let parts = url.split(separator: "/")
        guard parts.count >= 6, parts[0] == "https:", parts[4] == "pull" else { return "" }
        return "\(parts[2])/\(parts[3])"
    }
}

/// What the session tree draws: which workspace's agent started each workspace's agent (as acpmux
/// keeps `spawnedBy`), and each workspace's pull requests.
public nonisolated struct SidebarSessionTreeState: Hashable, Sendable {
    /// A child workspace to the workspace whose session started it.
    public var parents: [WorkspaceID: WorkspaceID]
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge]
    /// What each workspace's agents are doing, as acpmux decided it (the lanes); a workspace
    /// without a lane is read from its own row (`SidebarAgentState.of`).
    public var states: [WorkspaceID: SidebarAgentState] {
        didSet {
            laneStates = states
            needsPerson = Set(states.compactMap { Self.needsPerson($0.value) ? $0.key : nil })
        }
    }
    /// The complete lane state map used for hidden-row visibility. `shape` keeps only the blocked projection in
    /// `states` so ordinary lane ticks do not invalidate the layout options, while this map preserves lane precedence
    /// over a stale hook state on the workspace row. It is intentionally excluded from value identity below.
    var laneStates: [WorkspaceID: SidebarAgentState]
    /// Agent-started sessions whose current state needs the person. This small projection lets the live tree
    /// distinguish a visibility-changing blocked transition from ordinary state ticks without comparing every lane.
    public private(set) var needsPerson: Set<WorkspaceID>
    /// Parents whose subtree the user folded: their descendants draw as the parent's roll-up.
    public var collapsed: Set<WorkspaceID>
    /// Parents below the top level the user opened (`foldsDeep` folds the others).
    public var opened: Set<WorkspaceID>
    /// Lineage nesting's default (Leo 2026-10-21, "didn't need to show up on the side by default"):
    /// a parent drawn below the top level starts folded, so a coordinator shows its lanes and each
    /// lane's own sessions wait in its roll-up until opened.
    public var foldsDeep: Bool
    /// Sessions started by agents stay out of the list (`sidebar.showAgentSessions` off, the default; Leo 2026-11-25
    /// about the nested helper sessions: "idk who asked for those in teh sidebar. it's weird"): a workspace with a
    /// parent draws no row, except one that needs the person (``SidebarAgentState/blocked``), one in `keeps` (the
    /// selection: a session opened from Command-K, a notification or its parent chat's list shows while selected),
    /// and the agent-started ancestors those draw under. The parent chat lists them (Session Info's Subagents).
    public var hidesStarted: Bool
    /// The agent-started sessions that draw while `hidesStarted` hides the rest: the selected ones.
    public var keeps: Set<WorkspaceID>

    public init(parents: [WorkspaceID: WorkspaceID] = [:], pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:],
                states: [WorkspaceID: SidebarAgentState] = [:], collapsed: Set<WorkspaceID> = [],
                opened: Set<WorkspaceID> = [], foldsDeep: Bool = false, hidesStarted: Bool = false,
                keeps: Set<WorkspaceID> = []) {
        self.init(parents: parents, pullRequests: pullRequests, states: states, laneStates: states,
                  collapsed: collapsed, opened: opened, foldsDeep: foldsDeep, hidesStarted: hidesStarted, keeps: keeps)
    }

    private init(parents: [WorkspaceID: WorkspaceID], pullRequests: [WorkspaceID: SidebarPullRequestBadge],
                 states: [WorkspaceID: SidebarAgentState], laneStates: [WorkspaceID: SidebarAgentState],
                 collapsed: Set<WorkspaceID>, opened: Set<WorkspaceID>, foldsDeep: Bool, hidesStarted: Bool,
                 keeps: Set<WorkspaceID>) {
        self.parents = parents
        self.pullRequests = pullRequests
        self.states = states
        self.laneStates = laneStates
        self.needsPerson = Set(states.compactMap { Self.needsPerson($0.value) ? $0.key : nil })
        self.collapsed = collapsed
        self.opened = opened
        self.foldsDeep = foldsDeep
        self.hidesStarted = hidesStarted
        self.keeps = keeps
    }

    /// `laneStates` is a visibility source carried through `shape`, not part of the layout shape's identity. The
    /// synthesized identity would make every running/idle tick invalidate the sidebar's order cache.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.parents == rhs.parents && lhs.pullRequests == rhs.pullRequests && lhs.states == rhs.states
            && lhs.needsPerson == rhs.needsPerson && lhs.collapsed == rhs.collapsed && lhs.opened == rhs.opened
            && lhs.foldsDeep == rhs.foldsDeep && lhs.hidesStarted == rhs.hidesStarted && lhs.keeps == rhs.keeps
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(parents)
        hasher.combine(pullRequests)
        hasher.combine(states)
        hasher.combine(needsPerson)
        hasher.combine(collapsed)
        hasher.combine(opened)
        hasher.combine(foldsDeep)
        hasher.combine(hidesStarted)
        hasher.combine(keeps)
    }

    /// Whether `state` keeps an agent-started session drawn while `hidesStarted` hides the rest: a question or a
    /// permission waits on the person. Nothing waiting on them is ever hidden.
    public static func needsPerson(_ state: SidebarAgentState) -> Bool { state == .blocked }

    /// The agent-started sessions `hidesStarted` leaves out of the list, as indices into `ids` (one list's workspaces,
    /// nil: a group or an item); none while it is off. `state` reads a row's state by index. A kept row (it needs the
    /// person, or `keeps` holds it) keeps every agent-started ancestor of it in the list too, so it draws under them.
    public func hiddenStarted(_ ids: [WorkspaceID?], state: (Int) -> SidebarAgentState) -> Set<Int> {
        guard hidesStarted, !parents.isEmpty else { return [] }
        var kept: Set<WorkspaceID> = []
        for (index, id) in ids.enumerated() {
            guard let id, parents[id] != nil, keeps.contains(id) || Self.needsPerson(state(index)) else { continue }
            var current: WorkspaceID? = id
            while let next = current, parents[next] != nil, kept.insert(next).inserted { current = parents[next] }
        }
        var hidden: Set<Int> = []
        for (index, id) in ids.enumerated() {
            if let id, parents[id] != nil, !kept.contains(id) { hidden.insert(index) }
        }
        return hidden
    }

    /// Whether a patch from `old` to `new` shows or hides an agent-started row while `hidesStarted` is on: it began or
    /// stopped waiting on the person. Its step, title or preview changes nothing of the sort.
    public func patchChangesHidden(from old: SidebarWorkspace?, to new: SidebarWorkspace) -> Bool {
        guard hidesStarted, parents[new.id] != nil, !keeps.contains(new.id) else { return false }
        let lane = states[new.id]
        guard let old else { return Self.needsPerson(SidebarAgentState.of(new, lane: lane)) }
        return Self.needsPerson(SidebarAgentState.of(old, lane: lane)) != Self.needsPerson(SidebarAgentState.of(new, lane: lane))
    }

    /// Whether the parent `id`, drawn at `depth`, folds its subtree: the user folded it, or it is
    /// below the top level (`foldsDeep`) and the user did not open it.
    public func isFolded(_ id: WorkspaceID, depth: Int) -> Bool {
        collapsed.contains(id) || (foldsDeep && depth > 0 && !opened.contains(id))
    }

    /// The ancestors `id` draws under in one list, nearest first, as `SidebarLayout.treeChildren` nests it: the
    /// chain of parents `inList` holds; a parent outside the list ends it (that row is a root there). A chain that
    /// runs into a cycle draws no nesting at all: empty.
    public func drawnAncestors(of id: WorkspaceID, inList: (WorkspaceID) -> Bool) -> [WorkspaceID] {
        var seen: Set<WorkspaceID> = [id]
        var ancestors: [WorkspaceID] = []
        var current = id
        while let parent = parents[current], inList(parent) {
            guard seen.insert(parent).inserted else { return [] } // a cycle: every row of it is a root
            ancestors.append(parent)
            current = parent
        }
        return ancestors
    }

    /// Whether a folded ancestor hides `id` (its roll-up counts it) in one of `lists`, each a membership test of
    /// one list that lists `id` (the sidebar model's `listsHolding`: a workspace may be listed twice).
    public func hidesInFold(_ id: WorkspaceID, lists: [(WorkspaceID) -> Bool]) -> Bool {
        guard !hidesStarted else { return false } // no folds while agent-started rows hide (`treeRows`)
        guard !collapsed.isEmpty || foldsDeep else { return false }
        return lists.contains { list in
            let ancestors = drawnAncestors(of: id, inList: list)
            // The last ancestor is the root (depth 0); each one before it is one deeper.
            return ancestors.enumerated().contains { isFolded($0.element, depth: ancestors.count - 1 - $0.offset) }
        }
    }

    /// Whether a patch from `old` to `new` changes a folded ancestor's roll-up: `new` hides in a fold
    /// and its counted state moved. A hidden session's step, title or preview (many a second while
    /// it works) changes nothing drawn, so it lays nothing out (ask-268456b5a0). `lists` as ``hidesInFold(_:lists:)``
    /// takes them; by default one list holding every row.
    public func patchChangesRollUp(from old: SidebarWorkspace?, to new: SidebarWorkspace,
                                   lists: [(WorkspaceID) -> Bool] = [{ _ in true }]) -> Bool {
        guard hidesInFold(new.id, lists: lists) else { return false }
        guard let old else { return true }
        let lane = states[new.id]
        return SidebarAgentState.of(old, lane: lane) != SidebarAgentState.of(new, lane: lane)
    }

    /// What the order and the Command-numbers need: the parents and the folds.
    /// While `hidesStarted` hides, it keeps the agent-started rows acpmux says wait on the person (their states, as
    /// `hiddenStarted` reads them), so the order shows what the list draws; no other state, which changes many times
    /// a second.
    public var shape: SidebarSessionTreeState {
        let waiting = hidesStarted ? states.filter { Self.needsPerson($0.value) && parents[$0.key] != nil } : [:]
        return SidebarSessionTreeState(parents: parents, pullRequests: [:], states: waiting, laneStates: states,
                                       collapsed: collapsed, opened: opened, foldsDeep: foldsDeep,
                                       hidesStarted: hidesStarted, keeps: keeps)
    }

    /// The state fields that can move a tree row, excluding lane states and pull-request answers. The live tree uses
    /// ``needsPerson`` separately so a blocked transition remains a shape change while ordinary work stays on the
    /// cheap state revision.
    fileprivate var structuralIdentity: SidebarSessionTreeState {
        var copy = self
        copy.states = [:]
        copy.pullRequests = [:]
        return copy
    }
}

/// The session tree's live state; nil while `sidebar.sessionTree` is off and no session has a parent, so the list
/// draws as before. The app's feed (`SidebarSessionTreeFeed`) writes it; the list and Command-number order read it.
@Observable @MainActor
public final class SidebarSessionTree {
    public static let shared = SidebarSessionTree()

    public var state: SidebarSessionTreeState? {
        didSet {
            // Only the agents' states moved (a lane's turn started or ended, many a second across 10,000 sessions):
            // `statesRevision`, which redraws no row unless a folded parent rolls them up. Anything else: the shape.
            if state?.parents != oldValue?.parents { parentsRevision &+= 1 }
            let nowNeedsPerson = state?.needsPerson
            let wasNeedsPerson = oldValue?.needsPerson
            // Pull-request answers travel in the same feed value as lane states, but badges patch their rows through
            // `pullRequestsRevision`. Compare only the tree's structural identity here so a badge read does not lay
            // out the whole sidebar. A state write with the same structural identity takes the cheap state path.
            if state?.structuralIdentity != oldValue?.structuralIdentity || nowNeedsPerson != wasNeedsPerson {
                shapeRevision &+= 1
            } else {
                statesRevision &+= 1
            }
        }
    }
    /// The lineage drawn last while acpmux's lanes were live (child to parent), kept across launches: the last run's,
    /// then this run's. While the lanes are not live (a launch before the watch's first page, a watch gap) the feed
    /// keeps these parents, so the rows nest from the first frame as they were and nothing un-nests and nests again
    /// when the lanes land (Leo, 2026-11-22, after a relaunch: "the sidebar re-rendered/re-ordered with some
    /// animations").
    @ObservationIgnored public var savedParents: [WorkspaceID: WorkspaceID] = [:] {
        didSet {
            guard savedParents != oldValue else { return }
            defaults.set(Dictionary(uniqueKeysWithValues: savedParents.map { ($0.key.rawValue, $0.value.rawValue) }),
                         forKey: Self.lineageKey)
        }
    }
    /// Every row's pull request badge, with the tree on or off.
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:] { didSet { pullRequestsRevision &+= 1 } }
    /// The parents the user folded (a chevron on the row), kept across launches.
    public private(set) var collapsed: Set<WorkspaceID> { didSet { shapeRevision &+= 1 } }
    /// The parents below the top level the user opened (they start folded), kept across launches.
    public private(set) var opened: Set<WorkspaceID> { didSet { shapeRevision &+= 1 } }
    /// Whether sessions started by agents list in the sidebar (nested under their parents, as before); nil reads the
    /// person's setting `sidebar.showAgentSessions` (off by default: they hide, `SidebarSessionTreeState.hidesStarted`).
    /// A test pins it.
    public var showsStartedOverride: Bool?
    /// `sidebar.showAgentSessions`, or the override.
    public var showsStarted: Bool { showsStartedOverride ?? DesignSettings.shared.sidebarSections.showAgentSessions }
    /// Moves on every write of the tree other than its agents' states alone (on or off, parents, pull requests in the
    /// tree, folds): what the list draws changes. A render compares this counter, never the tree's whole-list
    /// dictionaries (cmuxterm-hq#13493).
    public private(set) var shapeRevision: UInt64 = 0
    /// Moves on every write that changed the lineage (`SidebarSessionTreeState.parents`, nil and empty apart): a
    /// restore's arrival (`SidebarView.isRestoreArrival`) compares this, never the parents dictionary.
    public private(set) var parentsRevision: UInt64 = 0
    /// Moves on a write that changed only the agents' states (`SidebarSessionTreeState.states`).
    public private(set) var statesRevision: UInt64 = 0
    /// Moves on every write of `pullRequests`.
    public private(set) var pullRequestsRevision: UInt64 = 0
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, showsStarted: Bool? = nil) {
        self.defaults = defaults
        showsStartedOverride = showsStarted
        collapsed = Set((defaults.stringArray(forKey: Self.collapsedKey) ?? []).map(WorkspaceID.init))
        opened = Set((defaults.stringArray(forKey: Self.openedKey) ?? []).map(WorkspaceID.init))
        savedParents = Dictionary(((defaults.dictionary(forKey: Self.lineageKey) as? [String: String]) ?? [:])
            .map { (WorkspaceID($0.key), WorkspaceID($0.value)) }) { first, _ in first }
        // The first frame nests its rows as the last run drew them.
        if !savedParents.isEmpty { state = SidebarSessionTreeState(parents: savedParents) }
    }

    /// Forgets the saved lineage, and the tree it seeded if no feed pass replaced it (no acpmux here: no lanes will).
    public func dropSavedLineage() {
        if let seeded = state, seeded == SidebarSessionTreeState(parents: savedParents) { state = nil }
        savedParents = [:]
    }

    /// What the list draws: the live state with the user's folds, a parent below the top level
    /// folded until opened; nil while the tree is off.
    public var drawn: SidebarSessionTreeState? { drawn(keeping: []) }

    /// ``drawn`` with `selection` drawn too: while agent-started sessions hide (``showsStarted`` off), a selected one
    /// (opened from Command-K, a notification, the needs-you tray or its parent chat's list) shows under its parent
    /// until the selection moves on. Only selected sessions that have a parent change the answer, so selecting a
    /// person's row lays nothing out again.
    public func drawn(keeping selection: Set<WorkspaceID>) -> SidebarSessionTreeState? {
        let hides = !showsStarted
        return state.map { live in
            var drawn = live
            (drawn.collapsed, drawn.opened, drawn.foldsDeep) = (collapsed, opened, true)
            drawn.hidesStarted = hides
            if hides, !selection.isEmpty { drawn.keeps = selection.filter { live.parents[$0] != nil } }
            return drawn
        }
    }

    /// Folds or opens the subtree under `id`. `folded`: whether its row draws it folded now (a
    /// parent below the top level starts folded); nil reads the user's own fold.
    public func toggle(_ id: WorkspaceID, folded: Bool? = nil) {
        if folded ?? collapsed.contains(id) {
            collapsed.remove(id)
            opened.insert(id)
        } else {
            collapsed.insert(id)
            opened.remove(id)
        }
        save()
    }

    /// Opens every fold above `id` (a selected session, or one the needs-you tray goes to) in each of `lists`
    /// (`hidesInFold`): only the parents it draws under there, so a parent in another list, or a cycle, opens nothing.
    public func reveal(_ id: WorkspaceID, lists: [(WorkspaceID) -> Bool]) {
        guard let state else { return }
        var folds = collapsed, opens = opened
        for list in lists {
            let ancestors = state.drawnAncestors(of: id, inList: list)
            for (n, parent) in ancestors.enumerated() {
                folds.remove(parent)
                if n < ancestors.count - 1 { opens.insert(parent) } // a parent below the top level
            }
        }
        guard folds != collapsed || opens != opened else { return }
        (collapsed, opened) = (folds, opens)
        save(pruning: false)
    }

    /// Saves the folds, dropping each one that is no longer a parent in the live tree (a closed
    /// workspace, or one whose sub-sessions ended), so the saved list never outgrows the tree. It
    /// prunes only on the user's own fold while the tree has parents: before the first pass every
    /// fold is kept, and `reveal` (which runs for the restored selection at launch, while the lanes
    /// may still be loading) never prunes.
    private func save(pruning: Bool = true) {
        if pruning, let parents = state?.parents, !parents.isEmpty {
            let live = Set(parents.values)
            collapsed = collapsed.filter(live.contains)
            opened = opened.filter(live.contains)
        }
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: Self.collapsedKey)
        defaults.set(opened.map(\.rawValue).sorted(), forKey: Self.openedKey)
    }

    static let collapsedKey = "sidebar.sessionTree.collapsed"
    static let openedKey = "sidebar.sessionTree.opened"
    static let lineageKey = "sidebar.sessionTree.savedLineage"
}

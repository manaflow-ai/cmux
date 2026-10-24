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
    /// Each pull request, newest first, for the badge's hover card (`sidebar.pullRequestCard`);
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
    public var states: [WorkspaceID: SidebarAgentState]
    /// Parents whose subtree the user folded: their descendants draw as the parent's roll-up.
    public var collapsed: Set<WorkspaceID>
    /// Parents below the top level the user opened (`foldsDeep` folds the others).
    public var opened: Set<WorkspaceID>
    /// Lineage nesting's default (Leo 2026-10-21, "didn't need to show up on the side by default"):
    /// a parent drawn below the top level starts folded, so a coordinator shows its lanes and each
    /// lane's own sessions wait in its roll-up until opened.
    public var foldsDeep: Bool

    public init(parents: [WorkspaceID: WorkspaceID] = [:], pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:],
                states: [WorkspaceID: SidebarAgentState] = [:], collapsed: Set<WorkspaceID> = [],
                opened: Set<WorkspaceID> = [], foldsDeep: Bool = false) {
        self.parents = parents
        self.pullRequests = pullRequests
        self.states = states
        self.collapsed = collapsed
        self.opened = opened
        self.foldsDeep = foldsDeep
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
        guard !collapsed.isEmpty || foldsDeep else { return false }
        return lists.contains { list in
            let ancestors = drawnAncestors(of: id, inList: list)
            // The last ancestor is the root (depth 0); each one before it is one deeper.
            return ancestors.enumerated().contains { isFolded($0.element, depth: ancestors.count - 1 - $0.offset) }
        }
    }

    /// What the order and the Command-numbers need: the parents and the folds.
    public var shape: SidebarSessionTreeState {
        SidebarSessionTreeState(parents: parents, collapsed: collapsed, opened: opened, foldsDeep: foldsDeep)
    }
}

/// The session tree's live state; nil while both `sidebar.sessionTree` and lineage nesting
/// (`SidebarTunables.lineageNesting`) are off, so the list draws as before. The app's feed (`SidebarSessionTreeFeed`) writes it; the list and Command-number order read it.
@Observable @MainActor
public final class SidebarSessionTree {
    public static let shared = SidebarSessionTree()

    public var state: SidebarSessionTreeState?
    /// Every row's pull request badge (`sidebar.pullRequestBadges`), with the tree on or off.
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:]
    /// The parents the user folded (a chevron on the row), kept across launches.
    public private(set) var collapsed: Set<WorkspaceID>
    /// The parents below the top level the user opened (they start folded), kept across launches.
    public private(set) var opened: Set<WorkspaceID>
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set((defaults.stringArray(forKey: Self.collapsedKey) ?? []).map(WorkspaceID.init))
        opened = Set((defaults.stringArray(forKey: Self.openedKey) ?? []).map(WorkspaceID.init))
    }

    /// What the list draws: the live state with the user's folds, a parent below the top level
    /// folded until opened; nil while the tree is off.
    public var drawn: SidebarSessionTreeState? {
        state.map { live in
            var drawn = live
            (drawn.collapsed, drawn.opened, drawn.foldsDeep) = (collapsed, opened, true)
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
}

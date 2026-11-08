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

/// What the session tree draws: which workspace's agent started each workspace's agent (one level,
/// as acpmux keeps `spawnedBy`), and each workspace's pull requests.
public nonisolated struct SidebarSessionTreeState: Hashable, Sendable {
    /// A child workspace to the workspace whose session started it.
    public var parents: [WorkspaceID: WorkspaceID]
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge]
    /// What each workspace's agents are doing, as acpmux decided it (the lanes); a workspace
    /// without a lane is read from its own row (`SidebarAgentState.of`).
    public var states: [WorkspaceID: SidebarAgentState]
    /// Parents whose subtree the user folded: their descendants draw as the parent's roll-up.
    public var collapsed: Set<WorkspaceID>

    public init(parents: [WorkspaceID: WorkspaceID] = [:], pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:],
                states: [WorkspaceID: SidebarAgentState] = [:], collapsed: Set<WorkspaceID> = []) {
        self.parents = parents
        self.pullRequests = pullRequests
        self.states = states
        self.collapsed = collapsed
    }

    /// Whether a folded ancestor hides `id` (its roll-up counts it).
    public func hidesInFold(_ id: WorkspaceID) -> Bool {
        guard !collapsed.isEmpty else { return false }
        var seen: Set<WorkspaceID> = [id]
        var current = id
        while let parent = parents[current], seen.insert(parent).inserted {
            if collapsed.contains(parent) { return true }
            current = parent
        }
        return false
    }

    /// Whether a patch from `old` to `new` changes a folded ancestor's roll-up: `new` hides in a fold
    /// and its counted state moved. A hidden session's step, title or preview (many a second while
    /// it works) changes nothing drawn, so it lays nothing out (ask-268456b5a0).
    public func patchChangesRollUp(from old: SidebarWorkspace?, to new: SidebarWorkspace) -> Bool {
        guard hidesInFold(new.id) else { return false }
        guard let old else { return true }
        let lane = states[new.id]
        return SidebarAgentState.of(old, lane: lane) != SidebarAgentState.of(new, lane: lane)
    }

    /// What the order and the Command-numbers need: the parents and the folds.
    public var shape: SidebarSessionTreeState { SidebarSessionTreeState(parents: parents, collapsed: collapsed) }
}

/// The session tree's live state; nil while `sidebar.sessionTree` is off, so the list draws as
/// before. The app's feed (`SidebarSessionTreeFeed`) writes it; the list and Command-number order read it.
@Observable @MainActor
public final class SidebarSessionTree {
    public static let shared = SidebarSessionTree()

    public var state: SidebarSessionTreeState?
    /// Every row's pull request badge (`sidebar.pullRequestBadges`), with the tree on or off.
    public var pullRequests: [WorkspaceID: SidebarPullRequestBadge] = [:]
    /// The parents the user folded (a chevron on the row), kept across launches.
    public private(set) var collapsed: Set<WorkspaceID>
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set((defaults.stringArray(forKey: Self.collapsedKey) ?? []).map(WorkspaceID.init))
    }

    /// What the list draws: the live state with the user's folds; nil while the tree is off.
    public var drawn: SidebarSessionTreeState? {
        state.map { live in
            var drawn = live
            drawn.collapsed = collapsed
            return drawn
        }
    }

    /// Folds or opens the subtree under `id`.
    public func toggle(_ id: WorkspaceID) {
        if collapsed.remove(id) == nil { collapsed.insert(id) }
        save()
    }

    /// Opens every fold above `id` (a selected session, or one the needs-you tray goes to).
    public func reveal(_ id: WorkspaceID) {
        var seen: Set<WorkspaceID> = [id]
        var current = id, opened = collapsed
        while let parent = state?.parents[current], seen.insert(parent).inserted {
            opened.remove(parent)
            current = parent
        }
        guard opened != collapsed else { return }
        collapsed = opened
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
        }
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: Self.collapsedKey)
    }

    static let collapsedKey = "sidebar.sessionTree.collapsed"
}

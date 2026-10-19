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
        /// A draft, a conflict or a failed check: orange. It wins over the others.
        case attention

        public static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var count: Int
    public var status: Status

    public init(count: Int, status: Status) {
        self.count = count
        self.status = status
    }

    /// One badge for several pull requests: their count, in the most urgent one's color.
    public static func combining(_ statuses: [Status]) -> SidebarPullRequestBadge? {
        guard let worst = statuses.max() else { return nil }
        return SidebarPullRequestBadge(count: statuses.count, status: worst)
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

    /// What the order and the Command-numbers need: the parents and the folds.
    public var shape: SidebarSessionTreeState { SidebarSessionTreeState(parents: parents, collapsed: collapsed) }
}

/// The session tree's live state; nil while `sidebar.sessionTree` is off, so the list draws as
/// before. The app's feed (`SidebarSessionTreeFeed`) writes it; the list and Command-number order read it.
@Observable @MainActor
public final class SidebarSessionTree {
    public static let shared = SidebarSessionTree()

    public var state: SidebarSessionTreeState?
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
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: Self.collapsedKey)
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
        defaults.set(collapsed.map(\.rawValue).sorted(), forKey: Self.collapsedKey)
    }

    static let collapsedKey = "sidebar.sessionTree.collapsed"
}

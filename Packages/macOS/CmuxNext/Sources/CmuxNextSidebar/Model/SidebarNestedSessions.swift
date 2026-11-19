public import CmuxNextDesign
public import Foundation
public import Observation

/// One sub-session an agent started inside its harness (a Claude Code subagent, a Codex spawned
/// thread), as acpmux read it from the harness's store (`_acpmux/chat_subsessions`).
public nonisolated struct SidebarSubSession: Hashable, Sendable {
    public nonisolated enum State: String, Hashable, Sendable {
        case running, done, failed, idle
    }

    /// The harness's id for it; unique within its workspace.
    public var id: String
    /// The sub-session that started it; nil when the workspace's own chat did.
    public var parentID: String?
    public var title: String
    /// Its agent type or role, when the harness names one.
    public var kind: String?
    public var state: State

    public init(id: String, parentID: String? = nil, title: String, kind: String? = nil, state: State = .idle) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.kind = kind
        self.state = state
    }

    /// The status mark a sub-session row draws.
    public var indicator: StatusIndicatorState {
        switch state {
        case .running: .working
        case .failed: .error
        case .done, .idle: .idle
        }
    }
}

/// What the list draws of the nested sessions (`sidebar.nestedSessions`): each workspace's
/// sub-sessions and the person's folds. Rows are keyed `ws:<workspace>` and
/// `sub:<workspace>:<sub-session>` for the Rust tree (`sidebar_session_tree`).
public nonisolated struct SidebarNestedSessionsState: Hashable, Sendable {
    public var sessions: [WorkspaceID: [SidebarSubSession]]
    public var expanded: Set<String>
    public var collapsed: Set<String>
    public var expandedByDefault: Bool

    public init(sessions: [WorkspaceID: [SidebarSubSession]] = [:], expanded: Set<String> = [], collapsed: Set<String> = [],
                expandedByDefault: Bool = false) {
        self.sessions = sessions
        self.expanded = expanded
        self.collapsed = collapsed
        self.expandedByDefault = expandedByDefault
    }

    public static func rowID(_ workspace: WorkspaceID) -> String { "ws:" + workspace.rawValue }
    public static func rowID(_ workspace: WorkspaceID, _ sub: String) -> String { "sub:\(workspace.rawValue):\(sub)" }
}

/// The nested sessions' live state, part of the session tree's (`SidebarSessionTree.nested`). Its feed
/// (`SidebarNestedSessionsFeed`) writes `mode` and `sessions`; the list reads `drawn`. Folds persist per row
/// across launches.
@Observable @MainActor
public final class SidebarNestedSessions {
    public var mode: SidebarNestedSessionsMode = .never
    /// Each workspace's sub-sessions, newest first; a workspace without any has no entry.
    public var sessions: [WorkspaceID: [SidebarSubSession]] = [:]
    public private(set) var expanded: Set<String>
    public private(set) var collapsed: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
        collapsed = Set(defaults.stringArray(forKey: Self.collapsedKey) ?? [])
    }

    /// What the list draws; nil while `sidebar.nestedSessions` is `never`, so the list draws as before.
    public var drawn: SidebarNestedSessionsState? {
        guard mode != .never else { return nil }
        return SidebarNestedSessionsState(sessions: sessions, expanded: expanded, collapsed: collapsed,
                                          expandedByDefault: mode == .expanded)
    }

    /// Opens (`open: true`), folds (`false`) or flips (nil) the row `rowID` (a workspace's or a
    /// sub-session's), through the Rust fold model (`sidebar_session_tree_fold`). Whether it
    /// draws open now; nil when the fold could not be decided.
    @discardableResult
    public func fold(_ rowID: String, open: Bool? = nil) -> Bool? {
        var parents: [String] = []
        for (workspace, subs) in sessions where !subs.isEmpty {
            parents.append(SidebarNestedSessionsState.rowID(workspace))
            for parent in Set(subs.compactMap(\.parentID)) {
                parents.append(SidebarNestedSessionsState.rowID(workspace, parent))
            }
        }
        let request = RustNestedFoldRequest(expanded: expanded.sorted(), collapsed: collapsed.sorted(),
                                            expandedByDefault: mode == .expanded, id: rowID, open: open, parents: parents)
        guard let answer = RustSidebarClient.call("sidebar_session_tree_fold", request, as: RustNestedFoldResponse.self) else { return nil }
        expanded = Set(answer.expanded)
        collapsed = Set(answer.collapsed)
        defaults.set(answer.expanded, forKey: Self.expandedKey)
        defaults.set(answer.collapsed, forKey: Self.collapsedKey)
        return answer.open
    }

    /// Whether workspace `id`'s chevron is its sub-sessions': it has some, and the session tree draws no started
    /// workspace under it (that chevron is the tree's, and opens both).
    public static func foldsSubSessions(of id: WorkspaceID, tree: SidebarSessionTree = .shared) -> Bool {
        let nested = tree.nested
        guard nested.mode != .never, nested.sessions[id]?.isEmpty == false else { return false }
        return tree.drawn?.parents.values.contains(id) != true
    }

    static let expandedKey = "sidebar.nestedSessions.expanded"
    static let collapsedKey = "sidebar.nestedSessions.collapsed"
}

nonisolated struct RustNestedFoldRequest: Encodable {
    var expanded: [String]
    var collapsed: [String]
    var expandedByDefault: Bool
    var id: String
    var open: Bool?
    var parents: [String]
}

nonisolated struct RustNestedFoldResponse: Decodable {
    var expanded: [String]
    var collapsed: [String]
    var open: Bool
}

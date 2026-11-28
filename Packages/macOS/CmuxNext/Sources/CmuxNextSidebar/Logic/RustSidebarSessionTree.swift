import Foundation

/// The session tree's cold-path rules (`sidebar_session_tree`, cmux-layout-reducer's `sidebar_session_tree.rs`): the
/// pull request badge, which pull request pages the card opens, and the person's folds (toggle, reveal, prune). One
/// call per feed pass or per click; the per-row and per-layout rules (`hiddenStarted`, `isFolded`, `hidesInFold`)
/// stay in Swift, since a JSON round trip per row would cost more than the rule.
nonisolated enum RustSidebarSessionTree {
    static let operation = "sidebar_session_tree"

    // MARK: Badge

    private struct BadgeRequest: Encodable {
        let op = "badge"
        let items: [SidebarPullRequestItem]
    }

    private struct BadgeReply: Decodable {
        let count: Int
        let status: String
        let items: [SidebarPullRequestItem]
    }

    /// One badge for `items` (`combining(items:)`); nil when none is open or merged, or the reducer refuses.
    static func badge(_ items: [SidebarPullRequestItem]) -> SidebarPullRequestBadge? {
        guard !items.isEmpty,
              let reply = RustSidebarClient.call(operation, BadgeRequest(items: items), as: BadgeReply?.self) ?? nil,
              let status = SidebarPullRequestBadge.Status(wire: reply.status)
        else { return nil }
        return SidebarPullRequestBadge(count: reply.count, status: status, items: reply.items)
    }

    // MARK: Pull request URLs

    private struct OpenableRequest: Encodable {
        let op = "openable"
        let url: String
        let enterpriseHost: String?
    }

    private struct OpenableReply: Decodable { let openable: Bool }

    /// Whether the card may open `url` (`isOpenable(enterpriseHost:)`); false when the reducer refuses.
    static func isOpenable(_ url: String, enterpriseHost: String?) -> Bool {
        RustSidebarClient.call(operation, OpenableRequest(url: url, enterpriseHost: enterpriseHost),
                               as: OpenableReply.self)?.openable ?? false
    }

    private struct RepositoryRequest: Encodable {
        let op = "repository"
        let url: String
    }

    private struct RepositoryReply: Decodable { let repository: String }

    /// `owner/repo` of a pull request URL (`repository(of:)`); empty when the reducer refuses.
    static func repository(of url: String) -> String {
        RustSidebarClient.call(operation, RepositoryRequest(url: url), as: RepositoryReply.self)?.repository ?? ""
    }

    // MARK: Folds

    struct Folds: Decodable, Equatable {
        var collapsed: Set<WorkspaceID>
        var opened: Set<WorkspaceID>

        private enum CodingKeys: String, CodingKey { case collapsed, opened }

        init(collapsed: Set<WorkspaceID>, opened: Set<WorkspaceID>) {
            self.collapsed = collapsed
            self.opened = opened
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            collapsed = Set(try c.decode([String].self, forKey: .collapsed).map(WorkspaceID.init))
            opened = Set(try c.decode([String].self, forKey: .opened).map(WorkspaceID.init))
        }
    }

    private struct ToggleRequest: Encodable {
        let op = "toggle"
        let collapsed: [String]
        let opened: [String]
        let id: String
        let folded: Bool?
        let parents: [String: String]?
        let keeping: [String] = []
    }

    private struct RevealRequest: Encodable {
        let op = "reveal"
        let collapsed: [String]
        let opened: [String]
        let id: String
        let parents: [String: String]
        let lists: [[String]]
    }

    private struct PruneRequest: Encodable {
        let op = "prune"
        let collapsed: [String]
        let opened: [String]
        let parents: [String: String]?
        let keeping: [String] = []
    }

    /// Folds or opens the subtree under `id`, then drops folds that are no longer parents in `parents` (none before
    /// the first pass, `parents` nil or empty); nil when the reducer refuses.
    static func toggle(_ folds: Folds, id: WorkspaceID, folded: Bool?, parents: [WorkspaceID: WorkspaceID]?) -> Folds? {
        RustSidebarClient.call(operation, ToggleRequest(collapsed: wire(folds.collapsed), opened: wire(folds.opened),
                                                        id: id.rawValue, folded: folded, parents: parents.map(wire)),
                               as: Folds.self)
    }

    /// Opens every fold above `id` in each of `lists` (the ids of one list each); nil when nothing changes or the
    /// reducer refuses. Never prunes.
    static func reveal(_ folds: Folds, id: WorkspaceID, parents: [WorkspaceID: WorkspaceID],
                       lists: [Set<WorkspaceID>]) -> Folds? {
        let request = RevealRequest(collapsed: wire(folds.collapsed), opened: wire(folds.opened), id: id.rawValue,
                                    parents: wire(parents), lists: lists.map(wire))
        return RustSidebarClient.call(operation, request, as: Folds?.self) ?? nil
    }

    /// Drops each fold that is no longer a parent in `parents` (nothing while it is nil or empty); nil when the
    /// reducer refuses.
    static func prune(_ folds: Folds, parents: [WorkspaceID: WorkspaceID]?) -> Folds? {
        RustSidebarClient.call(operation, PruneRequest(collapsed: wire(folds.collapsed), opened: wire(folds.opened),
                                                       parents: parents.map(wire)),
                               as: Folds.self)
    }

    private static func wire(_ ids: Set<WorkspaceID>) -> [String] { ids.map(\.rawValue).sorted() }

    private static func wire(_ parents: [WorkspaceID: WorkspaceID]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: parents.map { ($0.key.rawValue, $0.value.rawValue) })
    }
}

extension SidebarPullRequestBadge.Status {
    /// The reducer's lowercase name (`BadgeStatus`).
    nonisolated init?(wire: String) {
        switch wire {
        case "merged": self = .merged
        case "passing": self = .passing
        case "attention": self = .attention
        case "failing": self = .failing
        default: return nil
        }
    }
}

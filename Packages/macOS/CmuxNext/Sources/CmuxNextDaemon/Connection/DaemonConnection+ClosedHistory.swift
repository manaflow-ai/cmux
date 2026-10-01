import Foundation

/// Closed history (`closed.list`, `closed.reopen`, resource API v2): the
/// session's newest 50 closed tabs, screens, and workspaces, and reopening
/// one of them as new objects.
extension DaemonConnection {
    /// One closed-history item, as `closed.list` lists it.
    public struct ClosedItem: Decodable, Sendable, Equatable {
        public enum Kind: String, Decodable, Sendable {
            case tab, screen, workspace
        }

        /// `closed_…` id, the `closed` param of `closed.reopen`.
        public var id: String
        public var kind: Kind
        public var name: String?
        /// The workspace it was closed from (`ws_…`).
        public var workspaceID: String?

        enum CodingKeys: String, CodingKey {
            case id, kind, name
            case workspaceID = "workspace_id"
        }

        public init(id: String, kind: Kind, name: String? = nil, workspaceID: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.workspaceID = workspaceID
        }
    }

    /// What `closed.reopen` created.
    public struct ReopenedItem: Decodable, Sendable, Equatable {
        /// The workspace that holds it (`ws_…`); a new one for a workspace.
        public var workspaceID: String
        public var tabIDs: [String]

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case tabIDs = "tab_ids"
        }

        public init(workspaceID: String, tabIDs: [String] = []) {
            self.workspaceID = workspaceID
            self.tabIDs = tabIDs
        }
    }

    /// Every retained closed item, newest first.
    public func closedItems() async throws -> [ClosedItem] {
        try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "closed.list", params: [:])
        }, as: [ClosedItem].self)
    }

    /// Reopens closed item `id` and removes it from the history. Fails with
    /// the daemon's `resource.not_found` once it was reopened or evicted.
    public func reopenClosed(_ id: String) async throws -> ReopenedItem {
        let key = "cmux-next-closed-reopen-" + UUID().uuidString.lowercased()
        let result = try await resourceRequest({ requestID in
            ResourceRequestEnvelope(id: requestID, operation: "closed.reopen", params: ["closed": .string(id)], idempotencyKey: key)
        }, as: ResourceMutationResult<ReopenedItem>.self)
        return result.value
    }
}

public import Foundation

/// One teammate a team Cloud machine's chats are shared with (classic
/// `GET /api/vm/{id}/chat-grants`, web/services/vms/chatGrants.ts). While the grant stands, the
/// machine's attach endpoint answers `vmKind: "owner"` to them, so cmux-tui starts their app chats.
public struct CloudChatGrant: Decodable, Equatable, Sendable {
    public let userId: String
    public let grantedBy: String
    /// ISO 8601, as the server sent it.
    public let createdAt: String

    public init(userId: String, grantedBy: String, createdAt: String) {
        self.userId = userId
        self.grantedBy = grantedBy
        self.createdAt = createdAt
    }
}

/// Current permission for a NEW app chat start, checked separately from an existing link's
/// cached vmKind. `none` after revoke or team departure prevents another managed chat start.
public enum CloudChatStartAccess: String, Decodable, Equatable, Sendable {
    case owner, granted, none
}

/// Sharing a team Cloud machine's chats: the classic web backend's `/api/vm/{id}/chat-grants`
/// routes, as the person's Stack session in the active team (``CloudAPIClient/send``). Anyone who
/// can reach the machine reads the list; only its creator (while still on its team) or a team admin
/// grants or revokes. A refusal is a ``CloudAPIError/http(status:code:message:action:traceId:)``
/// with the server's `error` code (`vm_chat_share_forbidden`, `vm_chat_grants_personal_machine`,
/// `vm_chat_grants_unavailable`, `vm_chat_grant_not_member`; ``CloudMachineShareRefusal``).
extension CloudAPIClient {
    /// The machine's grants; none for a personal-account machine.
    public func chatGrants(_ id: String) async throws -> [CloudChatGrant] {
        struct List: Decodable { var grants: [CloudChatGrant] }
        return try await send("GET", chatGrantsPath(id), as: List.self).grants
    }

    /// A side-effect-free GET: reads current team membership and grant state without creating
    /// a new attach token, waking a machine or writing a lease. Classic API only.
    public func chatStartAccess(_ id: String) async throws -> CloudChatStartAccess {
        struct Answer: Decodable { let chatStart: CloudChatStartAccess }
        return try await send("GET", "/api/vm/\(pathSegment(id))/chat-start-access", as: Answer.self).chatStart
    }

    /// Shares the machine's chats with `userID`. Idempotent: an existing grant is kept.
    public func grantChat(_ id: String, to userID: String) async throws {
        _ = try await send("PUT", chatGrantsPath(id) + "/" + pathSegment(userID), as: Ignored.self)
    }

    /// Takes the share back. Idempotent: false when there was none.
    @discardableResult
    public func revokeChat(_ id: String, from userID: String) async throws -> Bool {
        struct Revoked: Decodable { var revoked: Bool }
        return try await send("DELETE", chatGrantsPath(id) + "/" + pathSegment(userID), as: Revoked.self).revoked
    }

    /// Classic only: the Worker machines routes serve no grants.
    private func chatGrantsPath(_ id: String) -> String { "/api/vm/\(pathSegment(id))/chat-grants" }

    /// One path segment: an id never adds a segment, a query or a fragment.
    func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

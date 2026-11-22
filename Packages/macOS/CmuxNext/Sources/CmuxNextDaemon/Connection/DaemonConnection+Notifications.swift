import Foundation

/// Notification ledger mutations that only the resource API has
/// (`notification.clear`, resource API v2).
extension DaemonConnection {
    /// `notification.clear` result: the ids that left the ledger.
    public struct ClearedNotifications: Decodable, Sendable, Equatable {
        public var cleared: [String]
    }

    /// Removes retained notifications: one terminal's (`term_…`, a ledger
    /// entry's `terminal_id`), or every one in the session when nil. The
    /// daemon drops the matching unread markers and emits `tree-changed`.
    @discardableResult
    public func clearNotifications(terminal: String? = nil) async throws -> [String] {
        var params: [String: JSONValue] = [:]
        if let terminal { params["terminal_id"] = .string(terminal) }
        let fields = params
        let key = "cmux-next-notification-clear-" + UUID().uuidString.lowercased()
        let result = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "notification.clear", params: fields, idempotencyKey: key)
        }, as: ResourceMutationResult<ClearedNotifications>.self)
        return result.value.cleared
    }
}

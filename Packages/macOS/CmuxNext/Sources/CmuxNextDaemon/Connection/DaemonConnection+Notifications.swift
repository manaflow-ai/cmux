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
        return try await clearNotifications(fields: params)
    }

    /// Removes one retained notification by its ledger id (`notification_…`,
    /// a `list-notifications` entry's id), whatever posted it: a terminal, an
    /// agent chat or a view. The daemon drops its tab's unread marker with
    /// the last row of that tab. A daemon older than the `notification_id`
    /// scope refuses it as invalid.
    @discardableResult
    public func clearNotification(id: String) async throws -> [String] {
        try await clearNotifications(fields: ["notification_id": .string(id)])
    }

    /// ``clearNotification(id:)``, or on a daemon older than it the row's
    /// whole `terminal`. False when that daemon left the row (it has no
    /// terminal): the caller marks it read instead.
    public func clearNotification(id: String, orTerminal terminal: String?) async throws -> Bool {
        do {
            try await clearNotification(id: id)
        } catch let DaemonError.command(_, _, code?, _, _) where code == "validation.invalid" {
            guard let terminal else { return false }
            try await clearNotifications(terminal: terminal)
        }
        return true
    }

    private func clearNotifications(fields: [String: JSONValue]) async throws -> [String] {
        let key = "cmux-next-notification-clear-" + UUID().uuidString.lowercased()
        let result = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "notification.clear", params: fields, idempotencyKey: key)
        }, as: ResourceMutationResult<ClearedNotifications>.self)
        return result.value.cleared
    }
}

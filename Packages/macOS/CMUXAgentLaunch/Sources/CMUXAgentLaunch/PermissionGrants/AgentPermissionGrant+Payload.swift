public import Foundation

extension AgentPermissionGrant {
    /// The JSON-compatible form the `permissions.list` socket method returns.
    ///
    /// Dates are ISO 8601 strings; `expires_at` and `last_used_at` are
    /// omitted when unset.
    public var socketPayload: [String: Any] {
        let formatter = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": id.uuidString,
            "rules": rules,
            "granted_at": formatter.string(from: grantedAt),
            "use_count": useCount,
        ]
        switch scope {
        case .session(let id):
            payload["scope"] = "session"
            payload["session_id"] = id
        case .project(let root):
            payload["scope"] = "project"
            payload["root"] = root
        }
        if let reason { payload["reason"] = reason }
        if let expiresAt { payload["expires_at"] = formatter.string(from: expiresAt) }
        if let lastUsedAt { payload["last_used_at"] = formatter.string(from: lastUsedAt) }
        return payload
    }
}

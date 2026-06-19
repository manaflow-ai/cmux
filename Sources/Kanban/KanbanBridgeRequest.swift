import Foundation

/// A decoded request from the Kanban webview: `{ id, method, params }`.
///
/// Mirrors ``AgentSessionBridgeRequest``. Parameter accessors trim whitespace
/// and treat empty strings as absent, so a blank field is rejected the same way
/// a missing one is.
struct KanbanBridgeRequest {
    let id: String
    let method: String
    let params: [String: Any]

    init(body: Any) throws {
        guard let dictionary = body as? [String: Any],
              let id = dictionary["id"] as? String,
              let method = dictionary["method"] as? String else {
            throw KanbanBridgeError.invalidRequest
        }
        self.id = id
        self.method = method
        self.params = dictionary["params"] as? [String: Any] ?? [:]
    }

    /// A trimmed, non-empty string parameter, or `nil`.
    func string(_ key: String) -> String? {
        let trimmed = (params[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// A required trimmed, non-empty string parameter.
    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw KanbanBridgeError.missingParameter(key)
        }
        return value
    }

    /// A string parameter preserving surrounding whitespace (e.g. a task spec).
    func rawString(_ key: String) -> String? {
        params[key] as? String
    }

    /// A required `UUID` parameter (card identifiers cross the bridge as strings).
    func requiredUUID(_ key: String) throws -> UUID {
        let raw = try requiredString(key)
        guard let uuid = UUID(uuidString: raw) else {
            throw KanbanBridgeError.missingParameter(key)
        }
        return uuid
    }

    /// The required `column` parameter resolved into a ``KanbanColumn``.
    ///
    /// Uses the strict synthesized `init?(rawValue:)` (not the tolerant decoder),
    /// so an unknown column is rejected rather than silently coerced to backlog.
    func requiredColumn(_ key: String = "column") throws -> KanbanColumn {
        let raw = try requiredString(key)
        guard let column = KanbanColumn(rawValue: raw) else {
            throw KanbanBridgeError.invalidColumn(raw)
        }
        return column
    }

    /// The optional `backendKind` parameter, defaulting to ``KanbanBackendKind/cmux``.
    func backendKind(_ key: String = "backendKind") -> KanbanBackendKind {
        guard let raw = string(key), let kind = KanbanBackendKind(rawValue: raw) else {
            return .cmux
        }
        return kind
    }

    /// The optional `agentProvider` parameter resolved into an
    /// ``AgentSessionProviderID``, or `nil` when absent or unrecognized.
    func agentProvider(_ key: String = "agentProvider") -> AgentSessionProviderID? {
        guard let raw = string(key) else { return nil }
        return AgentSessionProviderID(rawValue: raw)
    }
}

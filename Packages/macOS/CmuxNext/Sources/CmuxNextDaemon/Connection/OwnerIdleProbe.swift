import Foundation

/// Whether a conversation owner does no work now, so the app may restart it
/// (`cmux.protocol/2` reads only). Idle means both:
/// - no participant types in any conversation of the person (`conversation.list`,
///   then `conversation.get`'s `typing`): a Chief types for its whole turn, and
///   the owner's own brain supervisor restarts a brain only when its typing set
///   is empty (cmux-tui `chief_brains.rs`), so this is the same turn signal;
/// - no other app or page is connected (`client.list`: a `frontend` client or a
///   WebSocket client other than this connection).
/// Any error answers false: a probe that cannot see the owner never restarts it.
public struct OwnerIdleProbe: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    public func isIdle() async -> Bool {
        do {
            let clients = try await read("client.list", [:])
            for client in clients.arrayValue ?? [] where client["self"]?.boolValue != true {
                if client["client_kind"]?.stringValue == "frontend" || client["transport"]?.stringValue != "unix" {
                    return false
                }
            }
            let conversations = try await read("conversation.list", [:])
            for summary in conversations.arrayValue ?? [] {
                guard let id = summary["id"]?.stringValue else { return false }
                let snapshot = try await read("conversation.get", ["conversation": .string(id), "tail": .number(1)])
                guard let typing = snapshot["typing"]?.arrayValue, typing.isEmpty else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    private func read(_ operation: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params)
        }, as: JSONValue.self)
    }
}

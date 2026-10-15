import Foundation

/// Whether a conversation owner does no work now, so the app may restart it
/// (`cmux.protocol/2` reads only). Idle means both:
/// - no participant types in any conversation of the person (`conversation.list`,
///   then `conversation.get`'s `typing`): a Chief types for its whole turn, and
///   the owner's own brain supervisor restarts a brain only when its typing set
///   is empty (cmux-tui `chief_brains.rs`), so this is the same turn signal;
/// - no other app, page or chat is connected (`client.list`: a client of a
///   `busyClientKinds` kind, or a WebSocket client, other than this connection).
///   An open `cmux chief` chat is a `chief-chat` client (cmux-tui cli/chief).
/// Any error answers false: a probe that cannot see the owner never restarts it.
public struct OwnerIdleProbe: Sendable {
    public let connection: DaemonConnection
    /// Client kinds that keep the owner busy: another app (`frontend`) and an open
    /// `cmux chief` chat (`chief-chat`).
    public static let busyClientKinds: Set<String> = ["frontend", "chief-chat"]

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    public func isIdle() async -> Bool {
        do {
            let clients = try await read("client.list", [:])
            for client in clients.arrayValue ?? [] where client["self"]?.boolValue != true {
                if let kind = client["client_kind"]?.stringValue, Self.busyClientKinds.contains(kind) { return false }
                if client["transport"]?.stringValue != "unix" { return false }
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

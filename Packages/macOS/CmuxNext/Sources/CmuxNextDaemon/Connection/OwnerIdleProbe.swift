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
///
/// ``Clients/reconnecting`` is the rule for this app's own cmux-tui, whose handoff keeps every
/// terminal: the app holds many `frontend` connections of its own there (each terminal view, the
/// page relay), and they, other apps and pages all reconnect to the next daemon. Only a client
/// that does not come back keeps it busy: a `cmux chief` chat or a terminal UI (`tui`), and a
/// local client that never named its kind and connected under ``callSeconds`` ago, which is a
/// `cmux` CLI or MCP call in flight. A cmux SDK client names no kind either: the daemon's own agent
/// screen detector holds two such connections for its whole life, so an older one is a plugin's or
/// script's standing connection and must not hold the restart forever.
public struct OwnerIdleProbe: Sendable {
    /// Which other clients keep the owner busy.
    public enum Clients: Sendable {
        /// Another app or chat (``OwnerIdleProbe/busyClientKinds``) and any WebSocket or remote client.
        case everyOther
        /// Only clients that do not reconnect by themselves: a chat or TUI, and a CLI call in flight.
        case reconnecting
    }

    public let connection: DaemonConnection
    public let clients: Clients
    /// Under ``Clients/reconnecting``, how long a local client without a kind counts as a call in flight.
    public let callSeconds: Double
    /// A minute: a CLI or MCP call takes seconds; the quiet restart tries again each minute.
    public static let standardCallSeconds: Double = 60
    /// Client kinds that keep the owner busy: another app (`frontend`) and an open
    /// `cmux chief` chat (`chief-chat`).
    public static let busyClientKinds: Set<String> = ["frontend", "chief-chat"]
    /// Client kinds that keep this app's own cmux-tui busy under ``Clients/reconnecting``: an open
    /// `cmux chief` chat and a terminal UI attached to the session.
    public static let interactiveClientKinds: Set<String> = ["chief-chat", "tui"]

    public init(_ connection: DaemonConnection, clients: Clients = .everyOther,
                callSeconds: Double = Self.standardCallSeconds) {
        self.connection = connection
        self.clients = clients
        self.callSeconds = callSeconds
    }

    public func isIdle() async -> Bool {
        do {
            let clients = try await read("client.list", [:])
            for client in clients.arrayValue ?? [] where client["self"]?.boolValue != true {
                if keepsBusy(client) { return false }
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

    private func keepsBusy(_ client: JSONValue) -> Bool {
        let kind = client["client_kind"]?.stringValue
        switch clients {
        case .everyOther:
            if let kind, Self.busyClientKinds.contains(kind) { return true }
            return client["transport"]?.stringValue != "unix"
        case .reconnecting:
            // A page names no kind either, but it comes over the WebSocket listener and reconnects.
            guard let kind else { return client["transport"]?.stringValue == "unix" && connectedSeconds(client) < callSeconds }
            return Self.interactiveClientKinds.contains(kind)
        }
    }

    /// `connected_seconds` (a decimal string on the wire); unreadable counts as just connected.
    private func connectedSeconds(_ client: JSONValue) -> Double {
        let value = client["connected_seconds"]
        return value?.stringValue.flatMap(Double.init) ?? value?.doubleValue ?? 0
    }

    private func read(_ operation: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params)
        }, as: JSONValue.self)
    }
}

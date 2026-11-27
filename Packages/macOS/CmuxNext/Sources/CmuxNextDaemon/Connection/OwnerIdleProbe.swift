import Foundation

/// Whether a conversation owner does no work now, so the app may restart it
/// (`cmux.protocol/2` reads only). Idle means both:
/// - no participant types in any conversation of the person (`conversation.list`,
///   then `conversation.get`'s `typing`): a Chief types for its whole turn, and
///   the owner's own brain supervisor restarts a brain only when its typing set
///   is empty (cmux-tui `chief_brains.rs`), so this is the same turn signal;
/// - no other app, page, chat or call is connected (`client.list`: a client of a
///   `busyClientKinds` kind, a WebSocket client, or a local client that names no
///   kind and connected under ``callSeconds`` ago, other than this connection).
///   An open `cmux chief` chat is a `chief-chat` client (cmux-tui cli/chief). A
///   `cmux` CLI or MCP call names no kind: restarting the owner under one would
///   cut its request off. A cmux SDK client names no kind either, and the
///   daemon's own agent screen detector holds two such connections for its whole
///   life, so an older one is a standing connection and does not hold the restart.
/// Any error answers false: a probe that cannot see the owner never restarts it.
public struct OwnerIdleProbe: Sendable {
    /// What the probe saw.
    public enum Reading: Equatable, Sendable {
        case idle
        /// Busy until an owner event ends it (`IdleOwnerRestart.mayEndBusy`), or the
        /// probe could not read the owner.
        case busy
        /// Busy only with local clients without a kind (a call in flight); the youngest
        /// is a standing connection in `seconds` unless it leaves before.
        case callInFlight(seconds: Double)
    }

    public let connection: DaemonConnection
    /// How long a local client without a kind counts as a call in flight.
    public let callSeconds: Double
    /// A minute: a CLI or MCP call takes seconds.
    public static let standardCallSeconds: Double = 60
    /// Client kinds that keep the owner busy: another app (`frontend`) and an open
    /// `cmux chief` chat (`chief-chat`).
    public static let busyClientKinds: Set<String> = ["frontend", "chief-chat"]

    public init(_ connection: DaemonConnection, callSeconds: Double = Self.standardCallSeconds) {
        self.connection = connection
        self.callSeconds = callSeconds
    }

    public func isIdle() async -> Bool {
        await reading() == .idle
    }

    public func reading() async -> Reading {
        do {
            var call: Double = 0
            let clients = try await read("client.list", [:])
            for client in clients.arrayValue ?? [] where client["self"]?.boolValue != true {
                if client["transport"]?.stringValue != "unix" { return .busy }
                guard let kind = client["client_kind"]?.stringValue else {
                    call = max(call, callSeconds - Self.connectedSeconds(client))
                    continue
                }
                if Self.busyClientKinds.contains(kind) { return .busy }
            }
            let conversations = try await read("conversation.list", [:])
            for summary in conversations.arrayValue ?? [] {
                guard let id = summary["id"]?.stringValue else { return .busy }
                let snapshot = try await read("conversation.get", ["conversation": .string(id), "tail": .number(1)])
                guard let typing = snapshot["typing"]?.arrayValue, typing.isEmpty else { return .busy }
            }
            return call > 0 ? .callInFlight(seconds: call) : .idle
        } catch {
            return .busy
        }
    }

    /// `connected_seconds` (a decimal string on the wire, whole seconds); unreadable counts as just connected.
    private static func connectedSeconds(_ client: JSONValue) -> Double {
        let value = client["connected_seconds"]
        return value?.stringValue.flatMap(Double.init) ?? value?.doubleValue ?? 0
    }

    private func read(_ operation: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: params)
        }, as: JSONValue.self)
    }
}

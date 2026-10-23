public import CmuxHomeCore
public import CmuxNextDaemon
public import CmuxNextHome
public import Foundation

/// New Chief on this Mac's Chief owner, for an engine whose Chiefs are this Mac's
/// (``ChiefBackend/createsOnThisMac``: UniiChat, whose `unii login` lives here, and Codex):
/// `chief.profile.create` with the name and the engine's `harness` (the record's engine is the
/// brain's starting engine, cmux-tui chief_brains.rs `record_engine_env`), then the person's
/// direct message with the new Chief (`conversation-create`, ``HomeChiefDirectMessages/request(me:chief:name:)``), as the home-channels page does.
/// Both go on the app's trusted connection to the owner, so the owner takes them as the person's.
public nonisolated struct HomeLocalChiefCreator: Sendable {
    /// One owner operation (`operation`, `params`, idempotency key) and its raw result.
    public typealias Send = @Sendable (_ operation: String, _ params: [String: JSONValue], _ idempotencyKey: String) async throws -> JSONValue
    /// Creates a conversation on the owner and returns its id.
    public typealias Open = @Sendable (_ request: CreateConversationRequest) async throws -> String

    /// A Chief this made: its participant id and its direct message.
    public struct Created: Equatable, Sendable {
        /// The new Chief's id, its participant id in conversations.
        public var chief: String
        /// The person's direct message with it.
        public var conversation: ConversationID
    }

    private let me: ConversationParticipant
    private let send: Send
    private let open: Open

    /// - Parameters:
    ///   - me: the local user, the other member of the new Chief's direct message.
    ///   - send: the owner call for `chief.profile.create`.
    ///   - open: the owner call for `conversation-create`.
    public init(me: ConversationParticipant, send: @escaping Send, open: @escaping Open) {
        self.me = me
        self.send = send
        self.open = open
    }

    /// The creator over `connection`, the app's trusted connection to this Mac's Chief owner.
    public init(connection: DaemonConnection, me: ConversationParticipant) {
        self.init(me: me, send: { operation, params, key in
            try await ResourceRelayClient(connection: connection).send(operation: operation, params: params, idempotencyKey: key)
        }, open: { request in
            try await ConversationClient(connection).create(request).conversation.id
        })
    }

    /// `chief.profile.create`'s params: the display name, and the engine's `harness` unless it
    /// is the default one (the owner then applies its own, as `cmux chief new` does).
    public static func params(name: String, backend: ChiefBackend) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["display_name": .string(name)]
        if !backend.isDefault { params["harness"] = .string(backend.id) }
        return params
    }

    /// Makes the Chief and its direct message. A new key per call: a refused create's key
    /// would replay its refusal on a retry.
    public func create(name: String, backend: ChiefBackend) async throws -> Created {
        let key = "home-chief-create-" + UUID().uuidString.lowercased()
        let made = try await send("chief.profile.create", Self.params(name: name, backend: backend), key)
        // The mutation result (`{value: record, replayed}`), or the record itself.
        guard case .object(let reply) = made else { throw DaemonError.malformedResponse("chief.profile.create") }
        var record = reply
        if case .object(let value)? = reply["value"] { record = value }
        guard case .string(let chief)? = record["id"], !chief.isEmpty else {
            throw DaemonError.malformedResponse("chief.profile.create")
        }
        var shown = name
        if case .string(let named)? = record["display_name"], !named.isEmpty { shown = named }
        // The one key of this Chief's direct message: Home opening it for a Chief with no
        // conversation (a chief-changed event racing this create) replays it, never a second one.
        let request = HomeChiefDirectMessages.request(me: me, chief: chief, name: shown)
        return Created(chief: chief, conversation: ConversationID(try await open(request)))
    }
}

public import CmuxHomeCore
public import CmuxNextDaemon
public import CmuxNextHome
public import CmuxNextIPC
public import Foundation

/// New Chief on this Mac's Chief owner, for an engine whose Chiefs are this Mac's
/// (``ChiefBackend/createsOnThisMac``: UniiChat, whose `unii login` lives here, and Codex):
/// `chief.profile.create` with the name and the engine's `harness` (the record's engine is the
/// brain's starting engine, cmux-tui chief_brains.rs `record_engine_env`), then the person's
/// direct message with the new Chief (`conversation-create`, ``HomeChiefDirectMessages/request(me:chief:name:)``), as the home-channels page does.
/// Both go on the app's trusted connection to the owner, so the owner takes them as the person's.
public nonisolated struct HomeLocalChiefCreator: Sendable {
    /// The owner's `chief.profile.create` under an idempotency key, and its mutation result.
    public typealias Send = @Sendable (_ request: V2ChiefProfileCreateRequest, _ idempotencyKey: String) async throws
        -> V2ChiefProfileCreateRequest.Result
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
        self.init(me: me, send: { request, key in
            try await ResourceOperationClient(connection: connection).mutate(
                request, idempotencyKey: key, as: V2ChiefProfileCreateRequest.Result.self)
        }, open: { request in
            try await ConversationClient(connection).create(request).conversation.id
        })
    }

    /// `chief.profile.create` with the display name, and the engine's `harness` unless it is the
    /// default one (the owner then applies its own, as `cmux chief new` does).
    public static func request(name: String, backend: ChiefBackend) -> V2ChiefProfileCreateRequest {
        V2ChiefProfileCreateRequest(displayName: name, harness: backend.isDefault ? nil : backend.id)
    }

    /// Makes the Chief and its direct message. A new key per call: a refused create's key
    /// would replay its refusal on a retry.
    public func create(name: String, backend: ChiefBackend) async throws -> Created {
        let key = "home-chief-create-" + UUID().uuidString.lowercased()
        let record = try await send(Self.request(name: name, backend: backend), key).value
        let chief = record.id
        guard !chief.isEmpty else { throw DaemonError.malformedResponse("chief.profile.create") }
        let shown = record.displayName.isEmpty ? name : record.displayName
        // The one key of this Chief's direct message: Home opening it for a Chief with no
        // conversation (a chief-changed event racing this create) replays it, never a second one.
        let request = HomeChiefDirectMessages.request(me: me, chief: chief, name: shown)
        return Created(chief: chief, conversation: ConversationID(try await open(request)))
    }
}

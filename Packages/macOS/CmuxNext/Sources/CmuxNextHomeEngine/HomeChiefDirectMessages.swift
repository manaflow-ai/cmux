public import CmuxHomeCore
public import CmuxNextDaemon
public import Foundation

/// The person's direct message with each of this Mac's Chiefs, so every Chief is in the Home list
/// (its rows are conversations) from the moment it is made, not only after its first message.
///
/// A Chief made outside Home's New Chief (a Chief's `chiefs` tool, `cmux chief new`) gets a record
/// in the owner's registry (`chief.profile.create`) and no conversation, so the list had no row
/// for it (2026-10-22: the Codex Chief made by the chiefs tool was missing). ``open(missingFrom:)``
/// opens the direct message of each listed Chief that has no conversation here, under one
/// idempotency key per Chief (``key(for:)``), the key Home's own New Chief uses
/// (``HomeLocalChiefCreator``), so each Chief gets exactly one direct message whoever opens it first.
///
/// ```swift
/// let dms = HomeChiefDirectMessages(me: me, list: { listed }, open: { request in "conv_1" })
/// let opened = await dms.open(missingFrom: ["agent_mux"])
/// ```
public nonisolated struct HomeChiefDirectMessages: Sendable {
    /// The owner's `chief.profile.list` result.
    public typealias List = @Sendable () async throws -> JSONValue
    /// Creates a conversation on the owner and returns its id.
    public typealias Open = @Sendable (_ request: CreateConversationRequest) async throws -> String

    private let me: ConversationParticipant
    private let list: List
    private let open: Open

    /// - Parameters:
    ///   - me: The local user, the other member of each direct message.
    ///   - list: The owner call for `chief.profile.list`.
    ///   - open: The owner call for `conversation-create`.
    public init(me: ConversationParticipant, list: @escaping List, open: @escaping Open) {
        self.me = me
        self.list = list
        self.open = open
    }

    /// The opener over `connection`, the app's trusted connection to this Mac's Chief owner.
    public init(connection: DaemonConnection, me: ConversationParticipant) {
        self.init(me: me, list: {
            try await ResourceRelayClient(connection: connection).send(
                operation: "chief.profile.list", params: ["machine": .string("current"), "session": .string("current")], idempotencyKey: nil)
        }, open: { request in
            try await ConversationClient(connection).create(request).conversation.id
        })
    }

    /// The one idempotency key of the person's direct message with `chief`.
    public static func key(for chief: String) -> String { "home-chief-dm-" + chief }

    /// The `conversation-create` request of the person's direct message with `chief`, titled `name`.
    ///
    /// - Parameters:
    ///   - me: The local user.
    ///   - chief: The Chief's id, its participant id.
    ///   - name: The Chief's display name.
    /// - Returns: The request, keyed by ``key(for:)``.
    public static func request(me: ConversationParticipant, chief: String, name: String) -> CreateConversationRequest {
        let participant = ConversationParticipant(id: chief, kind: .agent, displayName: name, agentClass: "mux")
        return CreateConversationRequest(idempotencyKey: key(for: chief), title: name, participants: [me, participant])
    }

    /// Each Chief record's id and display name, in the owner's order, from a `chief.profile.list` result.
    static func records(_ listed: JSONValue) -> [(id: String, name: String)] {
        guard case .object(let reply) = listed else { return [] }
        var object = reply
        if case .object(let value)? = reply["value"] { object = value }
        guard case .array(let chiefs)? = object["chiefs"] else { return [] }
        return chiefs.compactMap { chief in
            guard case .object(let record) = chief, case .string(let id)? = record["id"], !id.isEmpty else { return nil }
            guard case .string(let name)? = record["display_name"], !name.isEmpty else { return (id, id) }
            return (id, name)
        }
    }

    /// Opens the direct message of each of the owner's Chiefs that `listed` (the Chiefs in a local
    /// conversation) does not hold. The default Chief is skipped: Home keeps its conversation.
    ///
    /// - Parameter listed: The participant ids of the Chiefs that already have a conversation here.
    /// - Returns: Each opened direct message by Chief id; a Chief whose open failed is left out.
    public func open(missingFrom listed: Set<String>) async -> [String: ConversationID] {
        guard let all = try? await list() else { return [:] }
        var opened: [String: ConversationID] = [:]
        for record in Self.records(all) where record.id != HomeChiefName.muxID && !listed.contains(record.id) {
            if let id = try? await open(Self.request(me: me, chief: record.id, name: record.name)) {
                opened[record.id] = ConversationID(id)
            }
        }
        return opened
    }
}

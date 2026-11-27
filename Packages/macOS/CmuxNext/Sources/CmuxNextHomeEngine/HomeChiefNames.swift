public import CmuxHomeCore
public import CmuxNextDaemon
import CmuxNextHomeModel
import Foundation

/// Each Chief's one name, by its conversation: what the Home list's tile, the chat header, the
/// settings card, the tab strip and banners all show (issue 26393: the Home card said "Chief", the
/// header "Mario", the list "Chief 2").
///
/// The name is the Chief's record: a cloud Chief's account record (`chief.list`), a Chief of this
/// Mac its registry record (`chief.profile.*`, which `home-inbox` names each Chief row with). This
/// value keeps only the renames being saved: one shows at once (``rename(_:to:record:)``) and stays
/// while the record still has a name it replaces; once the record leaves those names (the save
/// landed, or anyone renamed it since) ``settle(_:record:)`` drops it for good, so a later record
/// change, an undo back to the old name too, shows as it is. A refused save drops it at once
/// (``rollBack(_:name:)``). A conversation with no record keeps its own title.
///
/// ```swift
/// var names = HomeChiefNames()
/// names.rename("conv_1", to: "Mario", record: "Chief")
/// names.name(of: "conv_1", record: "Chief")   // "Mario", at once
/// names.settle("conv_1", record: "Mario")     // the record caught up: it decides from now on
/// ```
public nonisolated struct HomeChiefNames: Hashable, Sendable {
    /// A rename being saved, and the record names it replaces (the record's when it began, and
    /// an earlier rename's still being saved).
    nonisolated struct Pending: Hashable, Sendable, Codable {
        var name: String
        var replaces: Set<String>
    }

    /// The renames being saved by conversation id: the rules' `Names` (cmux-home-rules
    /// `chief_settings/chief_names.rs`), which `chief_settings.namesStep` / `namesOf` / `namesAll` read.
    private nonisolated struct State: Hashable, Sendable, Codable {
        var pending: [String: Pending] = [:]
    }

    private var state = State()

    public init() {}

    /// The name `conversation`'s Chief shows, given its record's name; nil when neither names it.
    /// Rust's `chief_settings.namesOf`.
    public func name(of conversation: ConversationID, record: String?) -> String? {
        do {
            let name: String? = try HomeRules.call("chief_settings.namesOf",
                                                   OfRequest(state: state, conversation: conversation.rawValue, record: record))
            return name
        } catch {
            return record.flatMap(Self.trimmed)
        }
    }

    /// Every named Chief conversation's name (the Home list's tiles), given each Chief's record name.
    /// Rust's `chief_settings.namesAll`.
    public func all(_ records: [ConversationID: String]) -> [ConversationID: String] {
        let request = AllRequest(state: state, records: Dictionary(records.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }))
        let names: [String: String] = (try? HomeRules.call("chief_settings.namesAll", request)) ?? [:]
        return Dictionary(names.map { (ConversationID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether a rename of `conversation` is still shown over its record.
    public func isPending(_ conversation: ConversationID) -> Bool { state.pending[conversation.rawValue] != nil }

    /// Shows `name` for `conversation`, whose record is named `record`, while its save runs.
    public mutating func rename(_ conversation: ConversationID, to name: String, record: String?) {
        step(.init(kind: "rename", conversation: conversation.rawValue, name: name, record: record))
    }

    /// The record of `conversation` is named `record` now: a rename it no longer waits on goes.
    public mutating func settle(_ conversation: ConversationID, record: String?) {
        step(.init(kind: "settle", conversation: conversation.rawValue, record: record))
    }

    /// The save of `name` was refused: the record's name shows again. A newer rename stays.
    public mutating func rollBack(_ conversation: ConversationID, name: String) {
        step(.init(kind: "rollBack", conversation: conversation.rawValue, name: name))
    }

    /// Rust's `chief_settings.namesStep`; a failed call leaves the renames as they are.
    private mutating func step(_ event: Event) {
        if let next: State = try? HomeRules.call("chief_settings.namesStep", StepRequest(state: state, event: event)) {
            state = next
        }
    }

    private nonisolated struct Event: Encodable {
        var kind: String
        var conversation: String
        var name: String?
        var record: String?
    }

    private nonisolated struct StepRequest: Encodable {
        var state: State
        var event: Event
    }

    private nonisolated struct OfRequest: Encodable {
        var state: State
        var conversation: String
        var record: String?
    }

    private nonisolated struct AllRequest: Encodable {
        var state: State
        var records: [String: String]
    }

    /// The registry name of this Mac's Chief whose conversation is `conversation`, from the owner's
    /// `home-inbox` rows: a Chief row's name is its Chief's registry name (spec `home-inbox`).
    public static func localRecord(of conversation: ConversationID, in rows: [HomeInboxRequest.Row]?) -> String? {
        localRecords(rows?.first { $0.id == conversation.rawValue }.map { [$0] })[conversation]
    }

    /// Each of this Mac's Chief rows' registry names by conversation (``localRecord(of:in:)``): a
    /// chief row's trimmed name that is no internal id, the first row of an id winning. Rust's
    /// `chief_settings.localRecords`.
    public static func localRecords(_ rows: [HomeInboxRequest.Row]?) -> [ConversationID: String] {
        guard let rows, !rows.isEmpty else { return [:] }
        let request = RowsRequest(rows: rows.map { .init(id: $0.id, kind: $0.kind, name: $0.name) })
        let records: [String: String] = (try? HomeRules.call("chief_settings.localRecords", request)) ?? [:]
        return Dictionary(records.map { (ConversationID($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated struct RowsRequest: Encodable {
        struct Row: Encodable { var id: String; var kind: String; var name: String }
        var rows: [Row]
    }

    /// `name` without the spaces around it; nil when nothing is left.
    public static func trimmed(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Renaming one of this Mac's Chiefs: its registry record (`chief.profile.update {display_name}`),
/// the one its list row, its own conversation's title (the owner retitles it) and the Channels page read.
/// A set-title op on the conversation alone left the record, and so the list, on the old name.
public nonisolated struct HomeLocalChiefRename: Hashable, Sendable {
    /// The Chief's id (its participant id; `agent_mux` for the default Chief).
    public var chief: String
    /// The new name, trimmed.
    public var name: String

    public init(chief: String, name: String) {
        self.chief = chief
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The owner operation.
    public var operation: String { "chief.profile.update" }

    /// The operation's params.
    public var params: [String: JSONValue] {
        ["chief": .string(chief), "display_name": .string(name), "machine": .string("current"), "session": .string("current")]
    }

    /// One key per rename of this Chief, `unique` telling renames apart.
    public func idempotencyKey(_ unique: String) -> String {
        "home-chief-rename-\(chief)-\(unique)"
    }

    /// Saves the rename on `connection`, the app's trusted connection to this Mac's Chief owner.
    /// Nil when saved, else why not.
    public func send(over connection: DaemonConnection) async -> HomeChiefRenameFailure? {
        do {
            _ = try await ResourceRelayClient(connection: connection).send(operation: operation, params: params,
                                                                           idempotencyKey: idempotencyKey(UUID().uuidString.lowercased()))
            return nil
        } catch {
            return Self.failure(error)
        }
    }

    /// The card's reason for an error of the owner call: the registry's refusals (chief_registry.rs
    /// `Refusal::reason`) in `operation.failed` details. Rust's `chief_settings.renameFailure`.
    public static func failure(_ error: any Error) -> HomeChiefRenameFailure {
        HomeChiefRenameFailure.ruled("chief_settings.renameFailure", error)
    }
}

/// Renaming a conversation that is no Chief's own (a group or a channel with a Chief) from its
/// header card: one set-title op on this Mac's Chief owner.
public nonisolated struct HomeConversationRename: Hashable, Sendable {
    /// The conversation's id.
    public var conversation: String
    /// The new title.
    public var name: String

    public init(conversation: String, name: String) {
        self.conversation = conversation
        self.name = name
    }

    /// Saves the title on `connection`; nil when saved, else why not.
    public func send(over connection: DaemonConnection) async -> HomeChiefRenameFailure? {
        let key = "home-chief-rename-\(UUID().uuidString.lowercased())"
        do {
            _ = try await ConversationClient(connection).op(
                ConversationOpRequest(conversation: conversation, idempotencyKey: key, transaction: nil, op: .setTitle(name)))
            return nil
        } catch {
            return Self.failure(error)
        }
    }

    /// The card's reason for an error of the set-title op. Rust's `chief_settings.conversationRenameFailure`.
    static func failure(_ error: any Error) -> HomeChiefRenameFailure {
        HomeChiefRenameFailure.ruled("chief_settings.conversationRenameFailure", error)
    }
}

extension HomeChiefRenameFailure {
    /// The failure rule `op` names for `error` (no command error: no connection).
    nonisolated static func ruled(_ op: String, _ error: any Error) -> HomeChiefRenameFailure {
        var wire = WireError(commandError: false, message: "", code: nil, details: nil)
        if case DaemonError.command(_, let message, let code, let details, _) = error {
            wire = WireError(commandError: true, message: message, code: code, details: details)
        }
        guard let reply: WireFailure = try? HomeRules.call(op, FailureRequest(error: wire)) else { return .noConnection }
        switch reply.kind {
        case "signedOut": return .signedOut
        case "changedElsewhere": return .changedElsewhere
        case "invalidName": return .invalidName
        case "notFound": return .notFound
        case "refused": return .refused(reply.message ?? "")
        default: return .noConnection
        }
    }

    private nonisolated struct WireError: Encodable {
        var commandError: Bool
        var message: String
        var code: String?
        var details: JSONValue?
    }

    private nonisolated struct FailureRequest: Encodable {
        var error: WireError
    }

    private nonisolated struct WireFailure: Decodable {
        var kind: String
        var message: String?
    }
}

public import CmuxHomeCore
public import CmuxNextDaemon
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
    struct Pending: Hashable, Sendable {
        var name: String
        var replaces: Set<String>
    }

    private var pending: [ConversationID: Pending] = [:]

    public init() {}

    /// The name `conversation`'s Chief shows, given its record's name; nil when neither names it.
    public func name(of conversation: ConversationID, record: String?) -> String? {
        let record = record.flatMap(Self.trimmed)
        if let pending = pending[conversation], pending.replaces.contains(record ?? "") { return pending.name }
        return record
    }

    /// Every named Chief conversation's name (the Home list's tiles), given each Chief's record name.
    public func all(_ records: [ConversationID: String]) -> [ConversationID: String] {
        var names = records.compactMapValues(Self.trimmed)
        for id in pending.keys { names[id] = name(of: id, record: records[id]) }
        return names
    }

    /// Whether a rename of `conversation` is still shown over its record.
    public func isPending(_ conversation: ConversationID) -> Bool { pending[conversation] != nil }

    /// Shows `name` for `conversation`, whose record is named `record`, while its save runs.
    public mutating func rename(_ conversation: ConversationID, to name: String, record: String?) {
        guard let name = Self.trimmed(name) else { return }
        var replaces: Set<String> = [record.flatMap(Self.trimmed) ?? ""]
        if let earlier = pending[conversation] { replaces.formUnion(earlier.replaces.union([earlier.name])) }
        replaces.remove(name)
        pending[conversation] = Pending(name: name, replaces: replaces)
    }

    /// The record of `conversation` is named `record` now: a rename it no longer waits on goes.
    public mutating func settle(_ conversation: ConversationID, record: String?) {
        guard let entry = pending[conversation], !entry.replaces.contains(record.flatMap(Self.trimmed) ?? "") else { return }
        pending[conversation] = nil
    }

    /// The save of `name` was refused: the record's name shows again. A newer rename stays.
    public mutating func rollBack(_ conversation: ConversationID, name: String) {
        guard pending[conversation]?.name == Self.trimmed(name) else { return }
        pending[conversation] = nil
    }

    /// The registry name of this Mac's Chief whose conversation is `conversation`, from the owner's
    /// `home-inbox` rows: a Chief row's name is its Chief's registry name (spec `home-inbox`).
    public static func localRecord(of conversation: ConversationID, in rows: [HomeInboxRequest.Row]?) -> String? {
        rows?.first { $0.id == conversation.rawValue }.flatMap(record)
    }

    /// Each of this Mac's Chief rows' registry names by conversation (``localRecord(of:in:)``).
    public static func localRecords(_ rows: [HomeInboxRequest.Row]?) -> [ConversationID: String] {
        Dictionary((rows ?? []).compactMap { row in record(row).map { (ConversationID(row.id), $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func record(_ row: HomeInboxRequest.Row) -> String? {
        guard row.kind == "chief", let name = trimmed(row.name), !name.isHomeInternalID else { return nil }
        return name
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

    /// The card's reason for an error of the owner call.
    public static func failure(_ error: any Error) -> HomeChiefRenameFailure {
        guard case DaemonError.command(_, let message, let code, let details, _) = error else { return .noConnection }
        var reason: String?
        if case .object(let details)? = details, case .string(let text)? = details["reason"] { reason = text }
        // The registry's refusals (chief_registry.rs `Refusal::reason`) in `operation.failed` details.
        if code == "validation.invalid" { return .invalidName }
        if reason == "chief_not_found" || reason == "deleted_chief" { return .notFound }
        if reason == "rev_mismatch" { return .changedElsewhere }
        return .refused(message.isEmpty ? (reason ?? code ?? "") : message)
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
        } catch DaemonError.command(_, let message, let code, _, _) {
            return code == "invalid_title" ? .invalidName : .refused(message.isEmpty ? (code ?? "") : message)
        } catch {
            return .noConnection
        }
    }
}

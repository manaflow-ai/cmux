public import CmuxHomeCore
public import CmuxNextDaemon
import Foundation

/// Each Chief's one name, by its conversation: what the Home list's tile, the chat header, the
/// settings card, the tab strip and banners all show (issue 26393: the Home card said "Chief", the
/// header "Mario", the list "Chief 2").
///
/// The name is the Chief's record: a cloud Chief's account record (`chief.list`), a Chief of this
/// Mac its registry record (`chief.profile.*`, which `home-inbox` names each Chief row with). A
/// rename being saved shows at once (``rename(_:to:)``) and stays until the record moves, to the
/// new name or anyone's later one; a refused save drops it (``rollBack(_:name:)``), so the record's
/// name shows again. A conversation with no record keeps its own title (nil here).
///
/// ```swift
/// var names = HomeChiefNames(records: ["conv_1": "Chief"])
/// names.rename("conv_1", to: "Mario")   // every surface: "Mario"
/// names.records["conv_1"] = "Mario"     // the record caught up; it decides again
/// ```
public nonisolated struct HomeChiefNames: Hashable, Sendable {
    /// A rename being saved, and the record's name when it began.
    struct Pending: Hashable, Sendable {
        var name: String
        var base: String?
    }

    /// Each Chief's record name by its conversation.
    public var records: [ConversationID: String]
    private var pending: [ConversationID: Pending] = [:]

    /// - Parameter records: Each Chief's record name by its conversation; blank names are left out.
    public init(records: [ConversationID: String] = [:]) {
        self.records = records.compactMapValues(Self.trimmed)
    }

    /// The name `conversation`'s Chief shows; nil when no record names it and no rename is being saved.
    public func name(of conversation: ConversationID) -> String? {
        let record = records[conversation]
        if let pending = pending[conversation], pending.base == record { return pending.name }
        return record
    }

    /// Every named Chief conversation's name (the Home list's tiles).
    public var all: [ConversationID: String] {
        var names = records
        for id in pending.keys { names[id] = name(of: id) }
        return names
    }

    /// Shows `name` for `conversation` while its save runs (and after, until the record moves).
    public mutating func rename(_ conversation: ConversationID, to name: String) {
        guard let name = Self.trimmed(name) else { return }
        pending[conversation] = Pending(name: name, base: records[conversation])
    }

    /// The save of `name` was refused: the record's name shows again. A newer rename stays.
    public mutating func rollBack(_ conversation: ConversationID, name: String) {
        guard pending[conversation]?.name == Self.trimmed(name) else { return }
        pending[conversation] = nil
    }

    /// The record names of this Mac's Chiefs from the owner's `home-inbox` rows: each Chief row's
    /// name, its Chief's registry name (spec `home-inbox`).
    public static func localRecords(_ rows: [HomeInboxRequest.Row]?) -> [ConversationID: String] {
        Dictionary((rows ?? []).compactMap { row in
            guard row.kind == "chief", let name = trimmed(row.name), !name.isHomeInternalID else { return nil }
            return (ConversationID(row.id), name)
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func trimmed(_ name: String) -> String? {
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

    /// One key per rename of this Chief to this name.
    public func idempotencyKey(_ unique: String = UUID().uuidString.lowercased()) -> String {
        "home-chief-rename-\(chief)-\(unique)"
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

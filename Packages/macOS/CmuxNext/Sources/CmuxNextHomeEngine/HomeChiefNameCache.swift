public import CmuxHomeCore
public import CmuxNextDaemon

/// The Chief names Home shows (``HomeChiefNames``), asked of the Rust rules through
/// ``HomeChiefNameCache``. A sidebar or routing pass reads them once per row, so each read
/// was a JSON encode, a `cmux_home_call` and a decode on the main thread. The rules stay in
/// Rust; this type only decides when to ask them.
public final class HomeChiefNameCache {
    public init() {}

    /// Every conversation's Chief name: the Cloud registry's name, else the local Chief
    /// row's, with pending renames applied (``HomeChiefNames/all(_:)``).
    ///
    /// - Parameters:
    ///   - rows: The Home inbox rows (``HomeInboxSource/rows``).
    ///   - rowsRevision: ``HomeInboxSource/revision``, bumped with each change to `rows`.
    ///   - cloud: The Cloud registry's Chiefs.
    ///   - renames: Pending renames.
    /// - Returns: Each named conversation's Chief name.
    public func names(
        rows: [HomeInboxRequest.Row]?, rowsRevision: Int, cloud: [HomeChiefRecord], renames: HomeChiefNames
    ) -> [ConversationID: String] {
        var records = HomeChiefNames.localRecords(rows)
        for chief in cloud {
            guard let conversation = chief.mainConversation, let name = HomeChiefNames.trimmed(chief.name) else { continue }
            records[ConversationID(conversation)] = name
        }
        return renames.all(records)
    }

    /// One conversation's Chief name (``HomeChiefNames/name(of:record:)``); inputs as in
    /// ``names(rows:rowsRevision:cloud:renames:)``.
    public func name(
        of conversation: ConversationID,
        rows: [HomeInboxRequest.Row]?, rowsRevision: Int, cloud: [HomeChiefRecord], renames: HomeChiefNames
    ) -> String? {
        renames.name(of: conversation, record: Self.record(of: conversation, rows: rows, cloud: cloud))
    }

    /// The registry's trimmed name for `conversation`, else its local Chief row's (uncached).
    ///
    /// - Parameters:
    ///   - conversation: The conversation.
    ///   - rows: The Home inbox rows.
    ///   - cloud: The Cloud registry's Chiefs.
    /// - Returns: Its Chief's record name, or nil when it is no Chief's.
    public static func record(of conversation: ConversationID, rows: [HomeInboxRequest.Row]?, cloud: [HomeChiefRecord]) -> String? {
        if let chief = cloud.first(where: { $0.mainConversation == conversation.rawValue }),
           let name = HomeChiefNames.trimmed(chief.name) { return name }
        return HomeChiefNames.localRecord(of: conversation, in: rows)
    }
}

public import CmuxHomeCore

/// My archived and deleted Chiefs, as Home's list and page see them: their conversations leave the
/// list (the history stays with the owner, read-only), and the page never opens one by itself.
public struct HomeArchivedChiefs {
    /// The archived and deleted Chiefs' agent ids (`HomeDirectory.archivedChiefs`).
    public var ids: Set<String>
    /// The signed-in person, never taken for the Chief of a conversation.
    public var me: ParticipantID?

    /// `ids`: the archived and deleted Chiefs (`HomeDirectory.archivedChiefs`); `me`: the signed-in person.
    public init(_ ids: Set<String>, me: ParticipantID?) {
        self.ids = ids
        self.me = me
    }

    /// A row as the Rust rule reads it: only Chief rows hide.
    private struct Row: Encodable {
        let id: String
        let kind: String
        let participants: [String]

        init(_ row: InboxRow) {
            id = row.id.rawValue
            kind = row.kind == .chief ? "chief" : "other"
            participants = row.summary.participants.map(\.id.rawValue)
        }
    }

    /// `chief_home.archived_*`'s request.
    private struct Request: Encodable {
        let ids: [String]
        let me: String?
        var rows: [Row] = []
        var than: String?
        var chief: String?
        var participants: [String] = []
    }

    private func request(rows: [InboxRow] = []) -> Request {
        Request(ids: ids.sorted(), me: me?.rawValue, rows: rows.map(Row.init))
    }

    /// The rows the list shows: an archived Chief's conversation is hidden (Rust `chief_home.archived_visible`).
    public func visible(_ rows: [InboxRow]) -> [InboxRow] {
        guard !ids.isEmpty else { return rows }
        struct Reply: Decodable { let visible: [String] }
        guard let reply: Reply = try? ChiefHomeRules().call("archived_visible", request(rows: rows)) else { return rows }
        // The reply keeps the rows' order: walk both.
        var shown = reply.visible[...]
        return rows.filter { row in
            guard shown.first == row.id.rawValue else { return false }
            shown = shown.dropFirst()
            return true
        }
    }

    /// How many Chief conversations of `rows` other than `id` the list shows (none: `id` is the person's only Chief).
    public func otherChiefs(than id: ConversationID, in rows: [InboxRow]) -> Int {
        struct Reply: Decodable { let count: Int }
        var request = request(rows: rows)
        request.than = id.rawValue
        let reply: Reply? = try? ChiefHomeRules().call("archived_other_chiefs", request)
        return reply?.count ?? rows.filter { $0.kind == .chief && $0.id != id }.count
    }

    /// The conversations of `rows` the list hides for an archived Chief (the Messages page's list
    /// filters them, as the native list did).
    public func hiddenConversations(_ rows: [InboxRow]) -> [ConversationID] {
        guard !ids.isEmpty else { return [] }
        struct Reply: Decodable { let hidden: [String] }
        let reply: Reply? = try? ChiefHomeRules().call("archived_hidden", request(rows: rows))
        return reply?.hidden.map { ConversationID(rawValue: $0) } ?? []
    }

    /// `chief` (the preferred Chief's conversation), unless Archive Chief or Delete Chief hid it: the
    /// page never opens an archived or deleted Chief by itself, on any path (its default, the Chief
    /// observation's follow, a gone conversation's replacement). One `listed` does not have stays
    /// (a new Chief's conversation the inbox lists a moment later), unless `participants` names it a
    /// deleted Chief's direct conversation: the owner leaves that one out of the list (`home-inbox`
    /// `deleted_chiefs`), so an unlisted row is no proof it may open (CMUX-40: the deleted Chief's
    /// whole conversation came back).
    ///
    /// - Parameters:
    ///   - chief: The preferred Chief's conversation id.
    ///   - listed: The rows the store lists now.
    ///   - participants: The participant ids of a conversation the owner has, listed or not; none
    ///     when it is not known.
    public func openable(_ chief: String?, listed: [InboxRow], participants: (String) -> [String] = { _ in [] }) -> String? {
        guard let chief else { return nil }
        struct Reply: Decodable { let openable: String? }
        var request = request(rows: listed.filter { $0.id.rawValue == chief })
        request.chief = chief
        if request.rows.isEmpty { request.participants = participants(chief) }
        // The rules not running: never open it by itself.
        return ((try? ChiefHomeRules().call("archived_openable", request)) as Reply?)?.openable
    }

    /// A direct conversation (the person and one other) whose other member is an archived or deleted
    /// Chief: Home never shows it, also when the owner's list no longer has its row. A group or a
    /// channel with that Chief stays, as the owner keeps it.
    public func hides(participants: [String]) -> Bool {
        struct Reply: Decodable { let hides: Bool }
        var request = request()
        request.participants = participants
        return ((try? ChiefHomeRules().call("archived_hides", request)) as Reply?)?.hides ?? false
    }
}

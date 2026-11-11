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

    /// The rows the list shows: an archived Chief's conversation is hidden.
    public func visible(_ rows: [InboxRow]) -> [InboxRow] {
        guard !ids.isEmpty else { return rows }
        return rows.filter { row in
            guard row.kind == .chief else { return true }
            return !row.summary.participants.contains { $0.id != me && ids.contains($0.id.rawValue) }
        }
    }

    /// The conversations of `rows` the list hides for an archived Chief (the Messages page's list
    /// filters them, as the native list did).
    public func hiddenConversations(_ rows: [InboxRow]) -> [ConversationID] {
        guard !ids.isEmpty else { return [] }
        let shown = Set(visible(rows).map(\.id))
        return rows.map(\.id).filter { !shown.contains($0) }
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
        let row = listed.filter { $0.id.rawValue == chief }
        guard !row.isEmpty else { return hides(participants: participants(chief)) ? nil : chief }
        return visible(row).isEmpty ? nil : chief
    }

    /// A direct conversation (the person and one other) whose other member is an archived or deleted
    /// Chief: Home never shows it, also when the owner's list no longer has its row. A group or a
    /// channel with that Chief stays, as the owner keeps it.
    public func hides(participants: [String]) -> Bool {
        participants.count == 2 && participants.contains { ids.contains($0) && $0 != me?.rawValue }
    }
}

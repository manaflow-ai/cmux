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

    /// `chief` (the preferred Chief's conversation), unless Archive Chief hid it from `listed`: the
    /// page never opens an archived Chief by itself, on any path (its default, the Chief
    /// observation's follow, a gone conversation's replacement). One `listed` does not have stays.
    public func openable(_ chief: String?, listed: [InboxRow]) -> String? {
        guard let chief else { return nil }
        let row = listed.filter { $0.id.rawValue == chief }
        return row.isEmpty || !visible(row).isEmpty ? chief : nil
    }
}

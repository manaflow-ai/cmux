import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHome
import Foundation

/// The owner's `home-inbox` rows as the Messages list's rows, field for field: each owned row is the
/// store's row (its people and preview) with the owner's kind, name, unread, pin and mark, in the
/// owner's order. Conversations the owner does not list (Cloud ones, until `home-inbox` has them) keep
/// this Mac's pins and marks: their pins follow the owner's, the others go among the owner's unpinned
/// rows by their time.
struct HomeInboxMapping {
    private(set) var rows: [InboxRow] = []
    private(set) var pinned: Set<ConversationID> = []
    private(set) var unreadMarks: Set<ConversationID> = []

    init(owned: [HomeInboxRequest.Row], listed: [InboxRow], pins: HomePins, unreadMarks marks: Set<ConversationID>) {
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ownedPinned: [InboxRow] = []
        var ownedRest: [InboxRow] = []
        for row in owned {
            guard var mapped = byID[ConversationID(row.id)] else { continue }
            mapped.kind = Self.kind(row.kind)
            mapped.title = row.name
            mapped.unread = row.unread
            mapped.isPinned = row.pinned
            if row.markedUnread { unreadMarks.insert(mapped.id) }
            if row.pinned {
                pinned.insert(mapped.id)
                ownedPinned.append(mapped)
            } else {
                ownedRest.append(mapped)
            }
        }
        let ownedIDs = Set(owned.map { ConversationID($0.id) })
        let others = listed.filter { !ownedIDs.contains($0.id) }
        let (otherPinned, otherRest) = pins.split(others)
        pinned.formUnion(otherPinned.map(\.id))
        unreadMarks.formUnion(marks.intersection(others.map(\.id)))
        rows = ownedPinned + otherPinned + Self.merged(ownedRest, otherRest)
    }

    /// The owner's kinds; a channel draws as a group (the list has no channel style of its own).
    static func kind(_ kind: String) -> CmuxHomeCore.ConversationSummary.Kind {
        switch kind {
        case "chief": .chief
        case "direct": .direct
        default: .group
        }
    }

    /// Two lists, each newest first, as one: the owner's order kept, another row before an owned row
    /// only when it is newer.
    static func merged(_ owned: [InboxRow], _ others: [InboxRow]) -> [InboxRow] {
        guard !others.isEmpty else { return owned }
        var result: [InboxRow] = []
        result.reserveCapacity(owned.count + others.count)
        var o = owned.startIndex, c = others.startIndex
        while o < owned.endIndex || c < others.endIndex {
            if c < others.endIndex, o == owned.endIndex || others[c].timestamp > owned[o].timestamp {
                result.append(others[c])
                c += 1
            } else {
                result.append(owned[o])
                o += 1
            }
        }
        return result
    }
}

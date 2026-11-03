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
            // The owner's name wins only when it is a name: an untitled DM row carries no name
            // (or, from an older daemon, its peer's raw id), and then the people's names stay.
            if !row.name.isEmpty, !row.name.isHomeInternalID { mapped.title = row.name }
            // A row the store knows only from the cache (no newest message yet) shows the owner's
            // preview, never an empty line under its name.
            if mapped.summary.lastMessage == nil, mapped.preview.isEmpty, let preview = row.preview, !preview.isEmpty {
                mapped.preview = preview
            }
            mapped.unread = row.unread
            mapped.isPinned = row.pinned
            mapped.summary.muted = row.muted ?? mapped.summary.muted
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

    /// The rows of several owners as one list: with one owner its own order; else pinned rows by pin
    /// position (each owner numbers its pins by time; none last), then the others newest first (spec `home-inbox`).
    static func ordered(_ lists: [[HomeInboxRequest.Row]]) -> [HomeInboxRequest.Row] {
        let all = lists.flatMap { $0 }
        guard lists.filter({ !$0.isEmpty }).count > 1 else { return all }
        let pinned: [HomeInboxRequest.Row] = all.filter(\.pinned).sorted {
            (lhs: HomeInboxRequest.Row, rhs: HomeInboxRequest.Row) -> Bool in
            (lhs.pinPosition ?? .max, lhs.id) < (rhs.pinPosition ?? .max, rhs.id)
        }
        let keyedRest: [(key: String, row: HomeInboxRequest.Row)] = all.filter { !$0.pinned }.map {
            (key: timeKey($0.activityAt), row: $0)
        }
        let rest: [HomeInboxRequest.Row] = keyedRest.sorted {
            (lhs: (key: String, row: HomeInboxRequest.Row), rhs: (key: String, row: HomeInboxRequest.Row)) -> Bool in
            lhs.key != rhs.key ? lhs.key > rhs.key : lhs.row.id < rhs.row.id
        }.map(\.row)
        return pinned + rest
    }

    /// An RFC 3339 UTC time with its fraction as exactly three digits, so two owners' times sort as text
    /// (the daemon's merge key: `...:07Z` is `...:07.000`).
    static func timeKey(_ time: String) -> String {
        let plain = time.hasSuffix("Z") ? String(time.dropLast()) : time
        let parts = plain.split(separator: ".", maxSplits: 1)
        let fraction = parts.count > 1 ? String(parts[1].prefix(3)) : ""
        return String(parts.first ?? "") + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0)
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

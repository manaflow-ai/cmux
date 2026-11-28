import CmuxMobileDesign
import Foundation

/// A Cloud machine can hold every chat it ever ran: the list draws the newest page
/// of them and grows by a page as the reader nears its end, instead of every chat sorted by id.
public enum CloudChatList {
    public static let pageSize = 100

    public static func newest(_ sessions: some Collection<AcpmuxSession>, shown: Int) -> (rows: [AcpmuxSession], hasOlder: Bool) {
        let own = sessions.filter { $0.peer == nil }
        let sorted = own.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.lastTurnEndedAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.lastTurnEndedAt ?? .distantPast
            return left != right ? left > right : lhs.id < rhs.id
        }
        return (Array(sorted.prefix(shown)), sorted.count > shown)
    }

    /// The list's end (``PagedListEdge``): more chats held than shown is `.more`; all shown is the
    /// end once the hub read the machine's whole list, Try Again if its read of older chats stopped
    /// short, and a spinner while it still reads them.
    public static func edge(hasOlder: Bool, listWhole: Bool, restStopped: Bool) -> PagedListEdge {
        if hasOlder { return .more }
        if listWhole { return .end }
        return restStopped ? .failed(String(localized: "Couldn't load older chats.")) : .loading
    }

    /// Whether the chat the phone was asked to open (a notification, a link) is reported
    /// unavailable: only once the hub read the machine's whole list on this connection and the chat
    /// is not in it. Until then it may be one of the older chats still on their way (the list comes
    /// in pages, CMUX-563), and the list shows instead. A chat already opened is never reported.
    public static func preferredUnavailable(_ preferred: String?, sessions: [String: AcpmuxSession],
                                            listWhole: Bool, opened: Bool) -> Bool {
        guard let preferred, !opened else { return false }
        return listWhole && sessions[preferred] == nil
    }
}

import Foundation

/// A Cloud machine can hold every chat it ever ran: the list draws the newest page
/// of them and grows by a page on request, instead of every chat sorted by id.
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
}

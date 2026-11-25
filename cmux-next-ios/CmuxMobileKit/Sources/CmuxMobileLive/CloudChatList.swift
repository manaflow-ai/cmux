import CmuxMobileAgentChat
import Foundation

/// A Cloud machine can hold every chat it ever ran: the list draws the newest page
/// of them and grows by a page on request, instead of every chat sorted by id.
///
/// acpmux picks and orders the page (`_acpmux/sessions {localOnly, topLevelOnly, limit}`: this
/// machine's chats, no side chat or session another chat's agent started, newest `updatedAt`
/// first, ties by `sessionId`), the order the Mac's lists and the
/// phone's Mac chats read too, so every device draws one order. The phone neither sorts nor
/// filters the list (acpmux `hub/session_pages.rs`, `the_mac_and_the_phone_read_one_order`).
public enum CloudChatList {
    public static let pageSize = 100

    /// The first `shown` chats as acpmux lists them, and whether older ones follow.
    public struct Listed: Equatable, Sendable {
        public var ids: [String]
        public var hasOlder: Bool
        /// The rows as the reply sent them, for a chat the watch has not told the hub of yet.
        var rows: [String: AcpmuxSession]

        public init(ids: [String] = [], hasOlder: Bool = false) {
            (self.ids, self.hasOlder, rows) = (ids, hasOlder, [:])
        }

        public static func == (lhs: Listed, rhs: Listed) -> Bool {
            lhs.ids == rhs.ids && lhs.hasOlder == rhs.hasOlder
        }

        /// The listed chats in acpmux's order, each as the hub knows it now (the watch keeps
        /// it current), else as the reply sent it.
        @MainActor public func sessions(in hub: AcpmuxHub) -> [AcpmuxSession] {
            ids.compactMap { hub.sessions[$0] ?? rows[$0] }
        }
    }

    /// The small, display-only part of a session row safe to keep in the phone cache.
    public struct CachedRow: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let displayName: String
        public let lastPrompt: String?

        public init(_ session: AcpmuxSession) {
            id = session.id
            displayName = session.displayName
            lastPrompt = session.lastPrompt.map { String($0.prefix(300)) }
        }
    }

    public struct CachedPage: Codable, Equatable, Sendable {
        public let rows: [CachedRow]
        public let hasOlder: Bool

        public init(rows: [CachedRow], hasOlder: Bool) {
            self.rows = rows
            self.hasOlder = hasOlder
        }
    }

    /// The params of a list read of the first `shown` chats.
    nonisolated static func params(shown: Int) -> JSONValue {
        .object(["localOnly": .bool(true), "topLevelOnly": .bool(true),
                 "limit": .number(Double(max(shown, 1)))])
    }

    /// Reads the first `shown` of this machine's chats from its acpmux.
    @MainActor public static func newest(_ hub: AcpmuxHub, shown: Int) async throws -> Listed {
        try listed(await hub.request("_acpmux/sessions", params(shown: shown), timeout: .seconds(20)))
    }

    /// A `_acpmux/sessions` reply as the list, in the order it came.
    nonisolated static func listed(_ reply: JSONValue) throws -> Listed {
        guard let entries = reply["sessions"]?.arrayValue else { throw CocoaError(.coderReadCorrupt) }
        let rows = entries.compactMap(AcpmuxSession.init)
        guard rows.count == entries.count else { throw CocoaError(.coderReadCorrupt) }
        var listed = Listed(ids: rows.map(\.id), hasOlder: reply["nextCursor"]?.stringValue != nil)
        listed.rows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return listed
    }
}

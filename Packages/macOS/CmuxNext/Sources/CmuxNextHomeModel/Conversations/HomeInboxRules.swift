public import CmuxHomeCore
import Foundation

/// The Home list's inbox rules (cmux-tui/crates/cmux-home-rules `inbox.*`) as the Swift types call
/// them: the values each op reads (``Row``, ``Pins``, ``Contact``), and one call that never throws
/// into a view. The pins, the list's sections, New Message's contacts, the sidebar's order and the
/// sidebar's width rules live in Rust (tests/inbox_parity.rs); the Swift types keep their APIs and
/// ask through a value of this.
package nonisolated struct HomeInboxRules: Sendable {
    package init() {}

    /// Runs `inbox.NAME` on `input`. A failure (the linked library without the op, a reply that
    /// does not decode) stops a debug build and returns `fallback` in a release one.
    package func call<In: Encodable, Out: Decodable>(_ name: String, _ input: In, fallback: @autoclosure () -> Out) -> Out {
        do {
            return try HomeRules.call("inbox.\(name)", input)
        } catch {
            assertionFailure(String(describing: error))
            return fallback()
        }
    }

    /// One list row as the rules read it (`inbox::model::Row`): the timestamp in seconds since 1970.
    package nonisolated struct Row: Encodable, Sendable {
        var id: String
        var kind: String
        var title: String
        var preview: String
        var timestamp: Double
        var unread: Int
        var mentions: Int
        var isPinned: Bool
        var isTyping: Bool
        var muted: Bool
        var isChannel: Bool
        var lastSeq: UInt64
        var participants: [Participant]

        package init(_ row: InboxRow) {
            id = row.id.rawValue
            kind = row.kind.rawValue
            title = row.title
            preview = row.preview
            timestamp = row.timestamp.timeIntervalSince1970
            unread = row.unread
            mentions = row.mentions
            isPinned = row.isPinned
            isTyping = row.isTyping
            muted = row.summary.muted
            isChannel = row.summary.isChannel
            lastSeq = row.summary.lastSeq
            participants = row.summary.participants
        }
    }

    package func rows(_ rows: [InboxRow]) -> [Row] { rows.map(Row.init) }

    /// `rows` named by `ids`, in that order; a repeated id takes the next row of that id.
    package func pick(_ ids: [String], from rows: [InboxRow]) -> [InboxRow] {
        var byID: [String: [InboxRow]] = [:]
        for row in rows { byID[row.id.rawValue, default: []].append(row) }
        var next: [String: Int] = [:]
        return ids.compactMap { id in
            let at = next[id, default: 0]
            guard let list = byID[id], at < list.count else { return nil }
            next[id] = at + 1
            return list[at]
        }
    }

    /// ``HomePins`` as the rules read and write it (`inbox::pins::Pins`).
    package nonisolated struct Pins: Codable, Sendable {
        var pinned: [String]
        var unpinned: [String]
        var positions: [String: UInt64]

        package init(pinned: [String], unpinned: [String], positions: [String: UInt64]) {
            self.pinned = pinned
            self.unpinned = unpinned
            self.positions = positions
        }
    }

    /// ``HomeContact`` as the rules read and write it (`inbox::model::Contact`).
    package nonisolated struct Contact: Codable, Sendable {
        var id: String
        var name: String
        /// `team`, `connection` or `agent`.
        var source: String

        package init(id: String, name: String, source: String) {
            self.id = id
            self.name = name
            self.source = source
        }
    }
}

public import Foundation

/// What a read-only agent-message row in a transcript shows: the folded row that names a turn's
/// agents, or one message between the Chief and one of its agents.
///
/// `HomeAgentMessages` puts this on the ``TranscriptItem`` rows it inserts, and the renderer
/// writes the words (localized, with the fold's link). The item's plain-text part stays a
/// word-free fallback for copy and search.
///
/// User 2026-10-30: "i want to be able to monitor the messages you send to other agents better",
/// and agent reports should reach the user by themselves, folded, with the full text a click away.
public struct HomeAgentMessageRow: Hashable, Sendable {
    /// Maximum peers named in a compact fold preview. The count still covers every message.
    public static let peerPreviewLimit = 3

    /// The row's role in its fold.
    public enum Kind: Hashable, Sendable {
        /// The fold: `count` messages with `peers` (agent ids, first-seen order), shown in full when `expanded`.
        case fold(count: Int, peers: [String], expanded: Bool)
        /// One message from `from` to `to`; `outgoing` is the Chief's message to the agent, else the agent's report.
        case message(from: String, to: String, outgoing: Bool, text: String)
    }

    /// The fold this row belongs to: a stable id from the Chief and the answer the messages follow.
    public var group: String
    /// What the row shows.
    public var kind: Kind

    /// Creates a row of `group`.
    ///
    /// - Parameters:
    ///   - group: The fold's id (``groupID(author:anchor:)``).
    ///   - kind: The fold, or one message in it.
    public init(group: String, kind: Kind) {
        self.group = group
        self.kind = kind
    }

    /// The fold id for the agent messages `author` sent after the transcript row keyed `anchor`.
    ///
    /// Lowercase hex (FNV-1a, 64-bit) so it fits a link path and stays the same across launches.
    public static func groupID(author: ParticipantID, anchor: IdempotencyKey) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(author.rawValue)\u{0}\(anchor.rawValue)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The link a click on a fold row follows to expand or collapse `group`: `cmux://agent-messages/<group>`.
    public static func toggleLink(group: String) -> String { "cmux://agent-messages/\(group)" }

    /// The fold `url` toggles, or nil when `url` is not a ``toggleLink(group:)``.
    public static func group(toggledBy url: URL) -> String? {
        guard url.scheme?.lowercased() == "cmux", url.host?.lowercased() == "agent-messages",
              url.query == nil, url.fragment == nil, url.user == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].isEmpty, parts[1].count == 16,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(parts[1])
    }
}

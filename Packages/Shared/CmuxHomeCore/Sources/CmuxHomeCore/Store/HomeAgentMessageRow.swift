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

    /// The first ``peerPreviewLimit`` of `peers` joined by `separator`, then the separator and "…"
    /// when there are more, so a fold of 300 agents stays one short line.
    public static func peerPreview(_ peers: [String], separator: String) -> String {
        let shown = peers.prefix(peerPreviewLimit).joined(separator: separator)
        return peers.count > peerPreviewLimit ? shown + separator + "…" : shown
    }

    /// The row's role in its fold.
    public enum Kind: Hashable, Sendable {
        /// The agents row (one pill per agent): `count` messages and status notes, one or more, with `peers`
        /// (agent ids, first-seen order), shown in full after it when `expanded`.
        case fold(count: Int, peers: [String], expanded: Bool)
        /// One message from `from` to `to`; `outgoing` is the Chief's message to the agent, else the agent's report.
        case message(from: String, to: String, outgoing: Bool, text: String)
        /// One status note from `peer`: why it stopped, and the note's own words (no parentheses).
        case note(peer: String, reason: StatusNote, text: String)
    }

    /// Why an agent stopped with no report, from the note the Chief producer writes in its place
    /// (optchat-chief `children.rs` and `spawns.rs`: "(stopped without a report: its session is Disconnected)").
    public enum StatusNote: Hashable, Sendable {
        /// Its session ended with no report; `session` is the session's state ("Disconnected", "Closed").
        case stopped(session: String)
        /// Its session no longer exists, so no report will come.
        case gone
        /// Its report could not be read.
        case unreadable
    }

    /// Where an agent of a fold stands, from its newest message in the fold.
    public enum PeerState: Hashable, Sendable {
        /// The Chief's message to it is the newest: it is working on it.
        case told
        /// Its report is the newest.
        case reported
        /// It stopped with no report (a status note).
        case stopped
    }

    /// The fold this row belongs to: a stable id from the Chief and the answer the messages follow.
    public var group: String
    /// What the row shows.
    public var kind: Kind
    /// For an agents row: each agent's state, in the order of its `peers`; empty for other rows.
    public var peerStates: [PeerState] = []
    /// For an agents row: the newest message's words (a one-line preview); nil for other rows.
    public var latest: String?
    /// For an agents row: each agent's title, in the order of its `peers`: the `Title:` line of the
    /// first message the Chief sent it (a spawn task's first line), else its first clause (``title(of:)``); the agent's id
    /// when the Chief sent it nothing here. Empty for other rows.
    public var peerTitles: [String] = []
    /// For an agents row: whether each agent, in the order of its `peers`, has a report newer than the one
    /// the person last opened (its unread dot). Empty for other rows.
    public var peerUnread: [Bool] = []

    /// About how many characters a title keeps before it is cut at a word edge (the pill clips the rest).
    public static let titleLength = 32

    /// A task's title: its `Title:` line, else its first clause (Markdown marks dropped): the first line cut
    /// at the first `:`, `,`, `;`, ` - ` or sentence end (`.` before a space), then at a word edge to about
    /// ``titleLength`` characters, with no trailing punctuation. Nil for a task with no words.
    public static func title(of text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.lowercased().hasPrefix("title:") }) {
            let title = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        guard let first = lines.first else { return nil }
        var clause = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // A quoted message's speaker header ("User (Nov 4): \"…\"", "User: …") names who spoke, not the task.
        if let colon = clause.range(of: ":"), isSpeakerHeader(clause[..<colon.lowerBound]) {
            clause = clause[colon.upperBound...].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”'")))
        }
        for mark in [":", ",", ";", " - ", ". ", "? ", "! "] {
            if let cut = clause.range(of: mark) { clause = String(clause[..<cut.lowerBound]) }
        }
        let words = clause.split(separator: " ")
        var title = ""
        for word in words {
            let next = title.isEmpty ? String(word) : title + " " + word
            if !title.isEmpty, next.count > titleLength { break }
            title = next
        }
        while let last = title.last, ".,;:!?-–—".contains(last) || last.isWhitespace { title.removeLast() }
        return title.isEmpty ? nil : title
    }

    /// Whether `head` (the words before a first line's `:`) is a speaker header: "User", "The user",
    /// "User (Nov 4)", "User msg 12" — a relayed quote's label, never a task's title.
    private static func isSpeakerHeader(_ head: Substring) -> Bool {
        let words = head.lowercased().split(separator: " ")
        guard let first = words.first, words.count <= 4 else { return false }
        return first == "user" || (first == "the" && words.dropFirst().first == "user")
    }

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
        hex("\(author.rawValue)\u{0}\(anchor.rawValue)")
    }

    /// `text` hashed (FNV-1a, 64-bit) as 16 lowercase hex digits.
    private static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The status note `text` is, or nil for any other message (a real report).
    ///
    /// A note is the whole message in parentheses on one line, in one of the Chief producer's three forms.
    public static func statusNote(_ text: String) -> StatusNote? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("("), line.hasSuffix(")"), !line.contains("\n") else { return nil }
        let inner = line.dropFirst().dropLast()
        let stopped = "stopped without a report: its session is "
        if inner.hasPrefix(stopped) { return .stopped(session: String(inner.dropFirst(stopped.count))) }
        if inner.hasPrefix("gone:") { return .gone }
        if inner.hasPrefix("its report could not be read") { return .unreadable }
        return nil
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

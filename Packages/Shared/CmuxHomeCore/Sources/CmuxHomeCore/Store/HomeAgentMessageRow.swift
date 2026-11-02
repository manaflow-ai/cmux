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
        /// The fold: `count` messages with `peers` (agent ids, first-seen order), shown in full when `expanded`.
        case fold(count: Int, peers: [String], expanded: Bool)
        /// One message from `from` to `to`; `outgoing` is the Chief's message to the agent, else the agent's report.
        case message(from: String, to: String, outgoing: Bool, text: String)
        /// The fold of `count` status notes (agents that stopped with no report) from `peers`, shown in
        /// full when `expanded`; `reason` is their one shared reason, nil when they differ.
        case notes(count: Int, peers: [String], reason: StatusNote?, expanded: Bool)
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

    /// The fold id of the status notes in fold `group` (they open and close apart from its messages).
    public static func notesGroup(_ group: String) -> String { hex("notes\u{0}\(group)") }

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

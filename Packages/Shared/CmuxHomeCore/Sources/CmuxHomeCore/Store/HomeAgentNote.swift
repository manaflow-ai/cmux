import Foundation

/// A message the person sent one of the Chief's agents from the agent pane's composer.
///
/// User 2026-11-03 (msg 19960): the person and the Chief share the agent's composer, and the Chief sees
/// what the person wrote. The note travels as a normal message in the Chief's chat whose text starts with
/// `[to <agent id>] `, the counterpart of the `[<agent id>] ` reports and the `[from <name>] ` messages the
/// Chief already reads, so the Chief relays it with `tell` and keeps it in its log.
///
/// ```swift
/// let note = HomeAgentNote(peer: "a963", text: "Use the 2x shot.")
/// note.message                                        // "[to a963] Use the 2x shot."
/// HomeAgentNote(parsing: "[to a963] Use the 2x shot.") // the same note
/// ```
public struct HomeAgentNote: Hashable, Sendable {
    /// The agent's id (`a963`).
    public var peer: String
    /// What the person wrote.
    public var text: String

    /// - Parameters:
    ///   - peer: The agent's id.
    ///   - text: What the person wrote.
    public init(peer: String, text: String) {
        self.peer = peer
        self.text = text
    }

    /// The note's text in the Chief's chat: `[to <peer>] <text>`.
    public var message: String { "[to \(peer)] \(text)" }

    /// The note a message of the Chief's chat carries.
    ///
    /// - Parameter message: The message's plain text.
    /// - Returns: Nil when the message is not a note to an agent.
    public init?(parsing message: String) {
        guard message.hasPrefix("[to "), let end = message.range(of: "] ") else { return nil }
        let peer = message[message.index(message.startIndex, offsetBy: 4)..<end.lowerBound]
        let text = message[end.upperBound...]
        guard !peer.isEmpty, !peer.contains(where: \.isWhitespace), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        self.init(peer: String(peer), text: String(text))
    }
}

public import Foundation

/// A person's reply to a report in the reports basket, as the host sends it.
///
/// `promptID` makes a retry safe: a send that passed its deadline may still
/// have been queued, so the same reply sent again keeps its id and the
/// receiver delivers it once. A changed reply (other text or another
/// session) is a new message with a new id.
///
/// ```swift
/// let reply = ReportReply(session: report.sender, text: text, retrying: unsent[report.id])
/// let sent = await onReply(reply)
/// ```
public nonisolated struct ReportReply: Sendable, Equatable {
    /// The session that gets the reply (the report's sender).
    public let session: String
    /// The reply text.
    public let text: String
    /// The reply's id, the same for every send of the same reply.
    public let promptID: String

    /// - Parameters:
    ///   - session: The session that gets the reply.
    ///   - text: The reply text.
    ///   - promptID: The reply's id.
    public init(session: String, text: String, promptID: String) {
        self.session = session
        self.text = text
        self.promptID = promptID
    }

    /// A reply whose id is `previous`'s when it is the same reply sent again
    /// (same session and text), else a new one.
    ///
    /// - Parameters:
    ///   - session: The session that gets the reply.
    ///   - text: The reply text.
    ///   - previous: The last reply to this report that was not sent, if any.
    ///   - mint: Makes a new id (tests pass their own).
    public init(session: String, text: String, retrying previous: ReportReply?,
                mint: () -> String = { UUID().uuidString }) {
        let promptID = previous.flatMap { $0.session == session && $0.text == text ? $0.promptID : nil } ?? mint()
        self.init(session: session, text: text, promptID: promptID)
    }
}

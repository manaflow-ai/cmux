public import Foundation

/// What `uploads.begin` carries so a file of any size, uploaded after the person's Send, still
/// sends (Leo, 2026-10-26: "I ALREADY SAID WE NEED ARBITARRILY LARGE FILES OF ANY TYPE").
///
/// The transaction:
/// 1. At the Send, the page reserves the send ticket for its prompt and chat:
///    `transport.gesture {intent: {method: "session/prompt", params: {promptId, sessionId}}}`.
/// 2. Each `uploads.begin` carries `{sessionId, promptId, ticket}` beside its file. The host holds
///    the ticket for that upload (``AgentPaneTransport/holdSendTicket(_:upload:sessionId:promptId:)``):
///    the ticket's connection, chat and prompt must be exactly these, and while any of its uploads
///    is in progress its clock stands still. An upload that makes no progress for
///    ``AgentPaneUserGestures/uploadStallLimit`` ends the hold and the ticket.
/// 3. Finish and cancel release the hold (``AgentPaneUserGestures/releaseUpload(_:)``). A newer
///    send's ticket, a prompt that goes out, the page's release and the connection's end drop the
///    ticket, and the uploads that held it are reported (``AgentPaneUserGestures/onUploadHoldsEnded``).
/// 4. The prompt (that `promptId`, to that chat) redeems the ticket once, after every upload
///    released it; no other frame, prompt or chat can.
public nonisolated struct AgentPaneUploadSendTicket: Equatable, Sendable {
    public let sessionId: String
    public let promptId: String
    public let ticket: String

    public init(sessionId: String, promptId: String, ticket: String) {
        self.sessionId = sessionId
        self.promptId = promptId
        self.ticket = ticket
    }

    /// The send ticket of `uploads.begin`'s params; nil when one of the three is missing or empty
    /// (the upload is refused: no upload goes without the person's Send).
    public init?(beginParams params: [String: Any]?) {
        guard let sessionId = params?["sessionId"] as? String, !sessionId.isEmpty,
              let promptId = params?["promptId"] as? String, !promptId.isEmpty,
              let ticket = params?["ticket"] as? String, !ticket.isEmpty else { return nil }
        self.init(sessionId: sessionId, promptId: promptId, ticket: ticket)
    }
}

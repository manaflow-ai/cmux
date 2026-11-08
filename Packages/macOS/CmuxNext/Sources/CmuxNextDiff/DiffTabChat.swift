public import CmuxNextAgentPane
import Foundation

/// The chat on this Mac that opened a diff tab (hq #7563): Send to agent hands it the tab's review
/// comments as one prompt, through acpmux (``AcpmuxReplySender``, the Feed's reply path).
public struct DiffTabChat: Sendable {
    /// The chat's acpmux session.
    public let session: String
    /// Delivers `(text, promptID)`; true when the chat took it. A resend with the same prompt id
    /// is delivered once.
    let deliver: @Sendable (String, String) async -> Bool
    /// The chat's review brief for a repository root (``AcpmuxReviewBrief``) as JSON; nil when
    /// there is no acpmux to ask.
    let brief: @Sendable (String) async throws -> Data?

    public init(session: String, deliver: @escaping @Sendable (String, String) async -> Bool,
                brief: @escaping @Sendable (String) async throws -> Data?) {
        self.session = session
        self.deliver = deliver
        self.brief = brief
    }

    /// The tab's chat when it runs on this Mac (`isLocal`), sent to through `replies`: this Mac's
    /// acpmux cannot reach a chat on another machine, so that tab keeps its comments and offers no
    /// send. Nil without a session.
    public static func local(session: String?, isLocal: Bool, replies: AcpmuxReplySender,
                             environment: AcpmuxEnvironment?) -> DiffTabChat? {
        guard isLocal, let session, !session.isEmpty else { return nil }
        let reader = environment.map { AcpmuxReviewBrief(socketPath: $0.socketPath) }
        return DiffTabChat(session: session, deliver: { text, promptID in
            await replies.send(session: session, text: text, promptID: promptID, environment: environment)
        }, brief: { root in
            try await reader?.read(session: session, root: root)
        })
    }

    func send(_ text: String, promptID: String) async -> Bool { await deliver(text, promptID) }
}

/// Why `DiffPageService.open(folder:source:in:focus:)` opened nothing.
public nonisolated enum DiffOpenFailure: Error, Sendable, Equatable {
    /// The folder is in no git repository (or the session host cannot say).
    case notRepository
    /// The folder's machine did not answer (#25581): the reason, naming the machine.
    case unavailable(String)
}

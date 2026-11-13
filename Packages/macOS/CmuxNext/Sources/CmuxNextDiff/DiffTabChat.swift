public import CmuxNextAgentPane
public import CmuxNextDaemonService
public import Foundation

/// The chat on this Mac that opened a diff tab (hq #7563): Send to agent hands it the tab's review
/// comments as one prompt, through acpmux (``AcpmuxReplySender``, the Feed's reply path).
public struct DiffTabChat: Sendable {
    /// The chat's acpmux session.
    public let session: String
    /// Delivers `(text, promptID)` through this Mac's acpmux; true when the chat took it. A resend
    /// with the same prompt id is delivered once. Nil when the tab's session host sends.
    let deliver: (@Sendable (String, String) async -> Bool)?
    /// The chat's review brief for a repository root (``AcpmuxReviewBrief``) as JSON; nil when
    /// there is no acpmux to ask.
    let brief: (@Sendable (String) async throws -> Data?)?

    public init(session: String, deliver: (@Sendable (String, String) async -> Bool)? = nil,
                brief: (@Sendable (String) async throws -> Data?)? = nil) {
        self.session = session
        self.deliver = deliver
        self.brief = brief
    }

    /// The chat whose acpmux session id is `session`, for a diff tab whose session host is `link`'s.
    public static func of(session: String?, on link: AgentPaneGitLink, replies: AcpmuxReplySender,
                          environment: AcpmuxEnvironment?) -> DiffTabChat? {
        of(session: session, hostSends: link.sendsDiffComments, isLocal: link.isLocal, replies: replies,
           environment: environment)
    }

    /// The tab's chat: sent to by its session host when that host answers `diff.comments.send`
    /// (`hostSends`), on any machine; otherwise only when it runs on this Mac (`isLocal`), through
    /// `replies`. Nil without a session, or for another machine whose host cannot send.
    public static func of(session: String?, hostSends: Bool, isLocal: Bool, replies: AcpmuxReplySender,
                          environment: AcpmuxEnvironment?) -> DiffTabChat? {
        guard let session, !session.isEmpty else { return nil }
        if hostSends {
            guard isLocal else { return DiffTabChat(session: session) }
            let reader = environment.map { AcpmuxReviewBrief(socketPath: $0.socketPath) }
            return DiffTabChat(session: session, brief: { root in
                try await reader?.read(session: session, root: root)
            })
        }
        guard isLocal else { return nil }
        let reader = environment.map { AcpmuxReviewBrief(socketPath: $0.socketPath) }
        return DiffTabChat(session: session, deliver: { text, promptID in
            await replies.send(session: session, text: text, promptID: promptID, environment: environment)
        }, brief: { root in
            try await reader?.read(session: session, root: root)
        })
    }

    func send(_ text: String, promptID: String) async -> Bool {
        guard let deliver else { return false }
        return await deliver(text, promptID)
    }
}

/// Why `DiffPageService.open(folder:source:in:focus:)` opened nothing.
public nonisolated enum DiffOpenFailure: Error, Sendable, Equatable {
    /// The folder is in no git repository (or the session host cannot say).
    case notRepository
    /// The folder's machine did not answer (#25581): the reason, naming the machine.
    case unavailable(String)
}

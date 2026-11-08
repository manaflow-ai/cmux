public import CmuxNextAgentPane
public import CmuxNextDaemonService
import Foundation

/// The chat that opened a diff tab (hq #7563): Send to agent hands it the tab's review comments as
/// one prompt. The tab's session host, on the chat's own machine, takes them with
/// `diff.comments.send`; a host from before that op reaches only a chat on this Mac, through this
/// Mac's acpmux (``AcpmuxReplySender``, the Feed's reply path).
public struct DiffTabChat: Sendable {
    /// The chat's acpmux session id on the machine that runs it.
    public let session: String
    /// Delivers `(text, promptID)` through this Mac's acpmux; true when the chat took it. A resend
    /// with the same prompt id is delivered once. Nil when the tab's session host sends.
    let deliver: (@Sendable (String, String) async -> Bool)?

    public init(session: String, deliver: (@Sendable (String, String) async -> Bool)? = nil) {
        self.session = session
        self.deliver = deliver
    }

    /// The chat whose acpmux session id is `session` (the id the chat's machine bound to its tab,
    /// `bind-conversation-tab-session`), for a diff tab whose session host is `link`'s: the chat's
    /// own machine (`DiffPageService.gitLink(for:)`).
    public static func of(session: String?, on link: AgentPaneGitLink, replies: AcpmuxReplySender,
                          environment: AcpmuxEnvironment?) -> DiffTabChat? {
        of(session: session, hostSends: link.sendsDiffComments, isLocal: link.isLocal, replies: replies, environment: environment)
    }

    /// The tab's chat: sent to by its session host when that host answers `diff.comments.send`
    /// (`hostSends`), on any machine; otherwise only when it runs on this Mac (`isLocal`), through
    /// `replies`, since this Mac's acpmux cannot reach a chat on another machine. Nil without a
    /// session, or for another machine's chat whose host cannot send.
    public static func of(session: String?, hostSends: Bool, isLocal: Bool, replies: AcpmuxReplySender,
                          environment: AcpmuxEnvironment?) -> DiffTabChat? {
        guard let session, !session.isEmpty else { return nil }
        if hostSends { return DiffTabChat(session: session) }
        guard isLocal else { return nil }
        return DiffTabChat(session: session) { text, promptID in
            await replies.send(session: session, text: text, promptID: promptID, environment: environment)
        }
    }
}

/// Why `DiffPageService.open(folder:source:in:focus:)` opened nothing.
public nonisolated enum DiffOpenFailure: Error, Sendable, Equatable {
    /// The folder is in no git repository (or the session host cannot say).
    case notRepository
    /// The folder's machine did not answer (#25581): the reason, naming the machine.
    case unavailable(String)
}

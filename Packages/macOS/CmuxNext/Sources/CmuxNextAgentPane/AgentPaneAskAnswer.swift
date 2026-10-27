public import Foundation

/// `chat.asks.answer {sessionId, permissionId, optionId}`: the home's inbox (webviews
/// `HomeInbox.tsx`) answered another chat's ask in place. The pane's relay may answer only the chat
/// it shows (its session scope), so the host answers this one itself, as the approval banners do
/// (``AcpmuxApprovalAnswerer``): one short person-proven connection to the chat's acpmux.
///
/// It answers only when every rule holds, else it answers nothing:
/// - The person's own click or permission shortcut is fresh in this pane
///   (``AgentPaneUserGestures/hasFreshAnswerGesture``), and the answer spends that click
///   (``AgentPaneUserGestures/consumeAnswerClick()``) right before the answer is sent: one click
///   answers one ask, typing after it does not renew it, a refusal before the send does not spend
///   it, and a script's post answers none.
/// - The chat is another chat on this pane's own acpmux on this Mac (``AgentPaneModel/pendingAsksSocket``,
///   a bare or `local/` id, ``AgentPanePendingAsks/localSession(_:)``), never the pane's own chat
///   (its card answers it) and never a chat another computer's daemon holds: both the read and the
///   answer name it `local/<id>`, which acpmux never forwards to a peer.
/// - The ask is still pending there as a tool permission (no question) of a chat that daemon holds
///   itself (`_acpmux/info` names no `peer`), and `optionId` is its `allow_once` or `reject_once`
///   option (``AcpmuxPermissionPrompt/onceOption(allow:offered:)``); an answer that lasts is the
///   chat's card's to give, where its scope is spelled out.
/// - acpmux binds a person connection's answer to the permissionId, not the prompt's
///   `decisionNonce` (that binds relayed decisions only), as the approval banners' answers.
/// - The answer counts only while that same request is pending unchanged (its digest), and an allow
///   only on a connection acpmux took as the person.
///
/// `unsupported` (the page then opens the chat, whose card answers): a pane on another machine, a
/// chat on another daemon or computer, or the pane's own chat. Any other refusal is `refused`, and
/// the inbox row says so. Kept off ``AgentPaneModel``, whose type is at its size limit.
public nonisolated struct AgentPaneAskAnswer: Sendable, Equatable {
    /// Which chat, which of its asks, which option.
    public var session: String
    public var permission: String
    public var option: String

    /// Longest id the op takes (acpmux ids are UUIDs; options are short names).
    static let maximumID = 256

    /// Exactly the three ids, each a non-empty string within ``maximumID``; nil otherwise.
    public init?(_ params: [String: Any]?) {
        guard let params, Set(params.keys) == ["sessionId", "permissionId", "optionId"] else { return nil }
        let ids = ["sessionId", "permissionId", "optionId"].compactMap { params[$0] as? String }
        guard ids.count == 3, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumID }) else { return nil }
        (session, permission, option) = (ids[0], ids[1], ids[2])
    }

    /// Makes the answerer for the acpmux of `environment` (tests pass a fake).
    public typealias MakeAnswerer = @MainActor (AcpmuxEnvironment) -> any AgentAskAnswering

    @MainActor func respond(in model: AgentPaneModel,
                            answerer make: MakeAnswerer = { AcpmuxApprovalAnswerer(environment: $0) }) async -> [String: Any] {
        let unsupported = AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: chat.asks.answer")
        guard let socket = model.pendingAsksSocket, let local = AgentPanePendingAsks.localSession(session),
              model.sessionId.flatMap(AgentPanePendingAsks.localSession) != local else { return unsupported }
        // A fresh click before any read: a post with no click reads and answers nothing. The click
        // is spent only by the answer it makes, so a refusal leaves it to the chat's own card.
        let gestures = model.transport.gestures
        guard gestures.hasFreshAnswerGesture else { return Self.refused("no fresh gesture") }
        guard let environment = await model.host.answerEnvironment(socket: socket) else { return unsupported }
        let answerer = make(environment)
        guard let pending = await answerer.pendingAsk(session: local, permission: permission) else {
            return Self.refused("not pending")
        }
        let allow = option == pending.allowOnce
        guard allow || option == pending.denyOnce else { return Self.refused("not a one-click option") }
        // The answerer spends the click right before it sends, after its re-read: a refusal
        // before the send leaves the click; one after it (a lost reply) does not.
        guard await answerer.answerOnce(pending.approval, allow: allow, spend: { gestures.consumeAnswerClick() }) else {
            return Self.refused("not answered")
        }
        return AgentPaneReply.success()
    }

    private static func refused(_ why: String) -> [String: Any] {
        AgentPaneReply.failure(code: "refused", message: "chat.asks.answer refused: \(why)")
    }
}

/// One pending tool permission of a chat, with the options a one-click allow and deny map to.
public nonisolated struct AgentPendingAsk: Sendable, Equatable {
    public var approval: AgentApproval
    /// The option an allow once sends, and the one a deny once sends; nil when the ask offers none.
    public var allowOnce: String?
    public var denyOnce: String?

    public init(approval: AgentApproval, allowOnce: String?, denyOnce: String?) {
        (self.approval, self.allowOnce, self.denyOnce) = (approval, allowOnce, denyOnce)
    }
}

/// Reads one ask of a chat and answers it, as ``AgentApprovalAnswering`` does for a banner.
@MainActor public protocol AgentAskAnswering: AnyObject {
    /// `permission` of `session` (a `local/<id>`) while it is pending as a tool permission of a
    /// chat the daemon holds itself; nil otherwise (answered, withdrawn, a question, a peer's chat,
    /// no acpmux to ask).
    func pendingAsk(session: String, permission: String) async -> AgentPendingAsk?
    /// Answers `approval` with its allow once or reject once while it is still pending unchanged
    /// in a chat the daemon holds itself; false when nothing was answered. `spend` is called once,
    /// after the re-read and right before the answer is sent; false from it sends nothing.
    func answerOnce(_ approval: AgentApproval, allow: Bool, spend: @MainActor () -> Bool) async -> Bool
}

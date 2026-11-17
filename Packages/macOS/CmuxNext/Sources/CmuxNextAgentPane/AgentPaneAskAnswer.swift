public import Foundation

/// `chat.asks.answer {sessionId, permissionId, optionId, answers?, annotations?}`: the home's inbox
/// (webviews `HomeInbox.tsx`), the composer hat or the Needs you list answered another chat's ask in
/// place: a tool permission's allow once or deny once, or (with `answers`) a question's whole reply,
/// as that chat's own question card would send it (webviews question/model.ts `reply`). Leo,
/// 2026-11-10, of a question he could only open: "this is unusable to respond to i necessarily have
/// to open... this is bad ui". The pane's relay may answer only the chat
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
/// - Or, with `answers`, the ask is still pending there as a question, and the reply passes
///   ``AgentPaneQuestionReply`` against that captured request (its one allow-once option, every
///   item answered as the card answers it, nothing looser than acpmux's own check). It is sent only
///   while the request is unchanged (its canonical digest), on a connection acpmux took as the person.
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
    /// A question's reply, `{optionId, answers, annotations?}` as canonical JSON; nil for a tool
    /// permission's one-click answer.
    public var reply: String?

    /// Longest id the op takes (acpmux ids are UUIDs; options are short names).
    static let maximumID = 256
    private static let ids: Set<String> = ["sessionId", "permissionId", "optionId"]

    /// The three ids, each a non-empty string within ``maximumID``, and for a question a non-empty
    /// `answers` object (with an optional `annotations` object); nil otherwise.
    public init?(_ params: [String: Any]?) {
        guard let params, Self.ids.isSubset(of: params.keys),
              Set(params.keys).isSubset(of: Self.ids.union(["answers", "annotations"])) else { return nil }
        let ids = ["sessionId", "permissionId", "optionId"].compactMap { params[$0] as? String }
        guard ids.count == 3, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= Self.maximumID }) else { return nil }
        (session, permission, option) = (ids[0], ids[1], ids[2])
        guard params["answers"] != nil || params["annotations"] != nil else { return }
        guard let answers = params["answers"] as? [String: Any], !answers.isEmpty else { return nil }
        var reply: [String: Any] = ["optionId": option, "answers": answers]
        if let raw = params["annotations"] {
            guard let annotations = raw as? [String: Any] else { return nil }
            reply["annotations"] = annotations
        }
        guard let json = AcpmuxSecretKey.canonicalJSON(reply),
              json.utf8.count <= AgentPaneQuestionReply.maximumReplyBytes else { return nil }
        self.reply = json
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
        if let reply { return await answerQuestion(local, reply: reply, answerer: answerer, gestures: gestures) }
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

    /// A question's reply: validated against the request acpmux holds now (never the page's copy),
    /// then sent while that same request is pending, spending the click right before the send.
    @MainActor private func answerQuestion(_ local: String, reply: String, answerer: any AgentAskAnswering,
                                           gestures: AgentPaneUserGestures) async -> [String: Any] {
        guard let pending = await answerer.pendingQuestion(session: local, permission: permission) else {
            return Self.refused("not a pending question")
        }
        let input = AgentPaneQuestionReply.Input(sessionId: local, permissionId: permission,
                                                  requestJSON: pending.requestJSON, requestDigest: pending.digest)
        guard let valid = try? AgentPaneQuestionReply(input: input, replyJSON: reply) else {
            return Self.refused("not a reply this question takes")
        }
        guard await answerer.answerQuestion(valid, spend: { gestures.consumeAnswerClick() }) else {
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

/// One pending question of a chat: the request acpmux holds, as JSON, and its canonical digest
/// (``AcpmuxSecretKey/canonicalDigest(_:)``), which ``AgentPaneQuestionReply`` checks it against.
public nonisolated struct AgentPendingQuestion: Sendable, Equatable {
    public var requestJSON: String
    public var digest: String

    public init(requestJSON: String, digest: String) {
        (self.requestJSON, self.digest) = (requestJSON, digest)
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
    /// `permission` of `session` while it is pending as a question of a chat the daemon holds
    /// itself; nil otherwise.
    func pendingQuestion(session: String, permission: String) async -> AgentPendingQuestion?
    /// Sends `reply` (validated against the request read by ``pendingQuestion(session:permission:)``)
    /// while that request is still pending unchanged, on a person connection; false when nothing was
    /// answered. `spend` is called once, after the re-read and right before the answer is sent.
    func answerQuestion(_ reply: AgentPaneQuestionReply, spend: @MainActor () -> Bool) async -> Bool
}

extension AgentAskAnswering {
    public func pendingQuestion(session: String, permission: String) async -> AgentPendingQuestion? { nil }
    public func answerQuestion(_ reply: AgentPaneQuestionReply, spend: @MainActor () -> Bool) async -> Bool { false }
}

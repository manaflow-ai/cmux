public import Foundation

/// `review.accept {sessionId, tag}` and `review.send {sessionId, text, tag, promptId}`: the Review
/// queue (webviews `review/ReviewScreen.tsx`) accepted a folder's changes, or asked the chat that made
/// them for changes. The pane's relay writes only to the chats it shows (its session scope), so the
/// host acts itself, as Needs you's answers do (``AgentPaneAskAnswer``), and only when every rule holds:
/// - The page is the Review queue (``AgentPaneNewTab/review``) on this Mac's acpmux
///   (``AgentPaneModel/pendingAsksSocket``), and the chat is a bare or `local/` id there, never another
///   computer's.
/// - The person's own key press or click is spent: Accept takes it as a grant
///   (``AgentPaneUserGestures/consume()``), a send as a prompt the person sent
///   (``AgentPaneUserGestures/consumeForSend()``). A script's post does neither.
/// - The only tag written is ``tagKey``, valued `accepted:<hex>` or `changes:<hex>` (the change's
///   signature), so the page cannot set any other tag.
/// - A send goes through `acpmux send --no-wait --no-steer --prompt-id` (``AcpmuxReplySender``): a retry with
///   the same prompt id is delivered once, and the tag is set only after acpmux took the prompt.
///
/// Kept off ``AgentPaneModel``, whose type is at its size limit.
public nonisolated struct AgentPaneReview: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case accept
        case send(text: String, promptID: String)
    }

    public var session: String
    public var tag: String
    public var verdict: Verdict

    /// The tag the Review queue reads (webviews `sessionList.ts` `REVIEW_DONE_TAG`).
    public static let tagKey = "review.done"
    static let maximumID = 256
    static let maximumText = 64 * 1024

    /// Exactly the method's keys, each a non-empty string within bounds, and a tag of the two
    /// verdicts; nil otherwise.
    public init?(method: String, params: [String: Any]?) {
        guard let params, let session = params["sessionId"] as? String, Self.isID(session),
              let tag = params["tag"] as? String, Self.isTag(tag) else { return nil }
        switch method {
        case "review.accept":
            guard Set(params.keys) == ["sessionId", "tag"], tag.hasPrefix("accepted:") else { return nil }
            verdict = .accept
        case "review.send":
            guard Set(params.keys) == ["sessionId", "tag", "text", "promptId"], tag.hasPrefix("changes:"),
                  let text = params["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= Self.maximumText,
                  let promptID = params["promptId"] as? String, Self.isID(promptID) else { return nil }
            verdict = .send(text: text, promptID: promptID)
        default:
            return nil
        }
        self.session = session
        self.tag = tag
    }

    private static func isID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= maximumID }

    /// `accepted:` or `changes:` and a hex signature of at most 64 digits.
    static func isTag(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let verdict = value[..<colon], signature = value[value.index(after: colon)...]
        return ["accepted", "changes"].contains(verdict) && (1...64).contains(signature.count)
            && signature.allSatisfy(\.isHexDigit)
    }

    /// Delivers `(session, text, promptID)` to acpmux; tags `session` (tests pass fakes).
    public typealias Deliver = @Sendable (AcpmuxEnvironment, String, String, String) async -> Bool
    public typealias Tag = @Sendable (String, String, [String: any Sendable]) async throws -> Void

    @MainActor func respond(
        in model: AgentPaneModel,
        deliver: Deliver = { environment, session, text, promptID in
            await AcpmuxReplySender().send(session: session, text: text, promptID: promptID, environment: environment)
        },
        tag setTag: Tag = { socket, session, set in
            _ = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/tag",
                                                  params: ["sessionId": session, "set": set], deadline: AcpmuxEnvironment.answerDeadline)
        }
    ) async -> [String: Any] {
        let method = verdict == .accept ? "review.accept" : "review.send"
        guard model.newTab?.review == true, let socket = model.pendingAsksSocket,
              let local = AgentPanePendingAsks.localSession(session) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
        }
        let gestures = model.transport.gestures
        switch verdict {
        case .accept:
            guard gestures.consume() else { return Self.refused(method, "no gesture") }
        case .send:
            guard gestures.consumeForSend() else { return Self.refused(method, "no gesture") }
        }
        guard let environment = await model.host.answerEnvironment(socket: socket) else {
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
        }
        if case .send(let text, let promptID) = verdict {
            guard await deliver(environment, local, text, promptID) else { return Self.refused(method, "not sent") }
        }
        do {
            try await setTag(socket, local, [Self.tagKey: tag])
        } catch {
            return Self.refused(method, "not tagged")
        }
        return AgentPaneReply.success()
    }

    private static func refused(_ method: String, _ why: String) -> [String: Any] {
        AgentPaneReply.failure(code: "refused", message: "\(method) refused: \(why)")
    }
}

public import CmuxNextAgentPane
public import CmuxNextPages

/// The GitHub page's review writes: a review of the pull request, and a reply to or a resolve of
/// one of its review threads. Each is one op of acpmux's GitHub host op (`review.submit`,
/// `thread.reply`, `thread.resolve`), which says it as the person: their own `gh` first; a comment
/// may fall back to the cmux GitHub App, an approval or a request for changes never does. Each
/// spends the person's click, and a thread must be one the page showed.
extension GitHubPageProvider {
    /// The verdicts a review may carry, GitHub's names.
    static let reviewEvents: Set<String> = ["COMMENT", "APPROVE", "REQUEST_CHANGES"]
    /// GitHub's own bound on a comment's body.
    static let maximumWords = 65_536

    /// A review of the pull request at `url`: `event` with `body`, pinned to `head` when given.
    func submitReview(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let link = try link(params, "review.submit")
        guard let event = params["event"]?.stringValue, Self.reviewEvents.contains(event) else {
            throw PageError.invalidParams("cmux.github.review.submit needs an event: COMMENT, APPROVE or REQUEST_CHANGES")
        }
        let body = try words(params, "review.submit", required: event != "APPROVE")
        guard spendGesture(context) else { throw PageError(code: "cmux.github.gesture_required", message: "Click to review") }
        var write: [String: any Sendable] = ["op": "review.submit", "repo": link.repository, "number": link.number,
                                             "event": event, "body": body]
        if let head = params["head"]?.stringValue, AgentPaneGitPullRequest.isCommit(head) { write["head"] = head }
        try await send(write, link: link, code: "cmux.github.review_refused")
        return ["submitted": .bool(true)]
    }

    /// A reply to, or a resolve (or unresolve) of, one review thread the page showed.
    func writeThread(_ method: String, _ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        let link = try link(params, method)
        guard let thread = params["thread"]?.stringValue, await shownThreads(link).contains(thread) else {
            throw PageError.invalidParams("cmux.github.\(method) names only a review thread the page showed")
        }
        var write: [String: any Sendable] = ["op": method, "repo": link.repository, "thread": thread]
        if method == "thread.reply" {
            write["body"] = try words(params, method, required: true)
        } else {
            guard let resolved = params["resolved"]?.boolValue else { throw PageError.invalidParams("cmux.github.thread.resolve needs resolved") }
            write["resolved"] = resolved
        }
        guard spendGesture(context) else { throw PageError(code: "cmux.github.gesture_required", message: "Click to reply") }
        try await send(write, link: link, code: "cmux.github.thread_refused")
        return ["done": .bool(true)]
    }

    /// `params`' `body`, at most GitHub's bound; empty only where it may be.
    private func words(_ params: JSONValue, _ method: String, required: Bool) throws -> String {
        let body = params["body"]?.stringValue ?? ""
        guard body.utf8.count <= Self.maximumWords,
              !required || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PageError.invalidParams("cmux.github.\(method) needs words, at most \(Self.maximumWords) bytes")
        }
        return body
    }

    /// The review threads of the details the page was given for `link`.
    private func shownThreads(_ link: GitHubLink) async -> Set<String> {
        guard let shown = await details[link.url]?.read.value else { return [] }
        return Set(shown.conversation.flatMap { $0.comments.compactMap(\.thread) })
    }

    /// Runs one write; GitHub's or acpmux's words when it did not take. What the page shows next
    /// (the conversation, the reviewers) is read again.
    private func send(_ write: [String: any Sendable], link: GitHubLink, code: String) async throws {
        let answer = await writer(write)
        // An approval or a request for changes with no gh login: the page says to sign in (its own sentence).
        guard answer.ok else {
            throw PageError(code: answer.reason == "github.person_only" ? "cmux.github.person_only" : code,
                            message: answer.refusal)
        }
        details[link.url] = nil
        _ = cache.answer(link.url)
    }
}

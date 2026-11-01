import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A failed turn's card says why in plain words (the Mac's failureCopy), with the agent's own
/// message under Details; the cmux model service's refusals get their own sentence.
@Suite struct TurnFailureCopyTests {
    static let routerForbidden = #"API Error: 403 {"error":{"code":"auth.forbidden","message":"this team cannot use the model router on this deployment yet","type":"invalid_request_error"}}"#

    @Test func cmuxModelServiceRefusalIsPlain() {
        let copy = TurnFailureCopy(message: Self.routerForbidden, harness: "cmux", harnessName: "Cmux")
        #expect(copy.kind == .modelServiceUnavailable)
        #expect(copy.sentence == "cmux's model service isn't available for this team.")
        #expect(copy.detail == Self.routerForbidden)
        // Same refusal, harness unknown: the message names the router.
        #expect(TurnFailureCopy(message: Self.routerForbidden).kind == .modelServiceUnavailable)
        let machine = #"API Error: 403 {"error":{"code":"auth.forbidden","message":"machine installs cannot use the model router yet"}}"#
        #expect(TurnFailureCopy(message: machine, harness: "cmux").sentence == "cmux's model service isn't available here.")
    }

    @Test func relayErrorsSayWhatToDo() {
        let notConnected = #"API Error: 503 {"error":{"code":"router.no_upstream","message":"the cmux model router is not connected; open cmux"}}"#
        #expect(TurnFailureCopy(message: notConnected, harness: "cmux").kind == .modelServiceNotConnected)
        let expired = #"API Error: 503 {"error":{"code":"router.upstream_expired","message":"the cmux model router sign-in expired; open cmux to renew it"}}"#
        #expect(TurnFailureCopy(message: expired, harness: "cmux").kind == .modelServiceExpired)
        let unreachable = #"API Error: 502 {"error":{"code":"router.unreachable","message":"the cmux model router did not answer"}}"#
        #expect(TurnFailureCopy(message: unreachable, harness: "cmux").kind == .modelServiceUnreachable)
    }

    @Test func macKindsCarryOver() {
        #expect(TurnFailureCopy(message: "API Error: 429 rate_limit_error", harness: "claude", harnessName: "Claude").sentence
            == "Claude is rate limited or out of capacity. Try again in a moment, or switch model.")
        #expect(TurnFailureCopy(message: "Unable to connect to API (ECONNREFUSED)", harness: "claude", harnessName: "Claude").kind == .unreachable)
        #expect(TurnFailureCopy(message: "Invalid API key · Please run /login", harness: "claude").kind == .subscriptionLogin)
        #expect(TurnFailureCopy(message: "API Error: 401 unauthorized", harness: "claude-sr", harnessName: "Claude").sentence
            == "subrouter refused Claude’s request (401). Check that route’s key or account.")
        #expect(TurnFailureCopy(message: "trust.pending: answer the trust question").kind == .trustPending)
    }

    /// Codex on a team Cloud machine whose team has no Codex account gets CodeRouter's 403 and shows
    /// only its message. It is not a rate limit or a refused route: the card names the fix.
    @Test func teamMachineWithoutAnAccountSaysSo() {
        let url = ", url: https://coderouter.cmux.dev/v1/responses, request id: req-1"
        let current = "unexpected status 403 Forbidden: Codex needs a team account on this machine. To add one for the team, run `cr add codex` in this machine's terminal. If someone added one as private, they can choose Share with team at coderouter.dev." + url
        let before = "unexpected status 403 Forbidden: No Codex account is shared with this Cloud machine's team. If one was added as private, the person who added it can choose Share with team at coderouter.dev, or add one here with `cr add codex` (accounts added on a Cloud machine are shared with its team). Or use your own Codex sign-in on this machine: run `cr use own codex`, then `codex login`." + url
        for message in [current, before] {
            let copy = TurnFailureCopy(message: message, harness: "codex", harnessName: "Codex")
            #expect(copy.kind == .noTeamAccount)
            #expect(copy.sentence == "Codex needs a team account on this machine. To add one for the team, run cr add codex in this machine’s terminal.")
            #expect(copy.detail == message)
        }
        // A real rate limit or capacity answer still says rate limited.
        for message in ["exceeded retry limit, last status: 503 Service Unavailable, request id: req-2", "unexpected status 429 Too Many Requests: Rate limit reached" + url] {
            #expect(TurnFailureCopy(message: message, harness: "codex", harnessName: "Codex").kind == .rateLimited)
        }
    }

    @Test func otherErrorsReadTheInnerMessage() {
        let copy = TurnFailureCopy(message: #"API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#)
        #expect(copy.kind == .other && copy.sentence == "Prompt is too long.")
        #expect(copy.detail != nil)
        // Plain text stays as it is, with no Details.
        let plain = TurnFailureCopy(message: "agent process closed")
        #expect(plain.sentence == "agent process closed" && plain.detail == nil)
        #expect(TurnFailureCopy(message: nil).sentence == "The turn ended with an error.")
    }

    @MainActor @Test func retryShowsWhileTheTurnRuns() {
        final class Silent: AgentSessionSource {
            let summary = AgentSessionSummary(id: "s", name: "S", harness: "cmux", agentName: "Cmux", cwd: "~", workspaceTitle: "w", macName: "m")
            func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
            func send(_ intent: AgentClientIntent) {}
        }
        let store = AgentChatStore(source: Silent())
        store.apply(.userMessage(text: "hi", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t", at: Date()))
        store.apply(.retrying(attempt: 2, maxAttempts: 10, status: 503))
        #expect(store.turns.last?.retry?.label == "Retrying (2 of 10, error 503)")
        store.apply(.turnResult(turnId: "t", status: .failed, errorText: Self.routerForbidden, at: Date()))
        #expect(store.turns.last?.retry == nil && store.turns.last?.status == .failed)
        // A retry after the turn ended changes nothing.
        store.apply(.retrying(attempt: 3, maxAttempts: 10, status: nil))
        #expect(store.turns.last?.retry == nil)
    }

    /// Full verify D4: the account refusing the chat's model reads as a sentence, never raw JSON.
    @Test func aModelTheAccountLacksIsPlain() {
        let raw = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}}"#
        let copy = TurnFailureCopy(message: raw, harness: "codex", harnessName: "Codex")
        #expect(copy.kind == .modelUnavailable)
        #expect(copy.sentence == "Codex can't use this model with the Mac's account. Pick another model.")
        #expect(copy.detail == raw)
        #expect(!TurnFailureCopy.plain(raw, harness: "codex", harnessName: "Codex").contains("{"))
        // A capacity error that mentions the model stays a capacity error.
        #expect(TurnFailureCopy(message: "The model is currently not available (503)").kind == .rateLimited)
        // Plain text stays as it is.
        #expect(TurnFailureCopy.plain("Already answered.") == "Already answered.")
    }
}


/// Full verify D13: a chat's preview is its newest agent message, not the turn's first.
@Suite struct LastAnswerTests {
    @Test func theLastMessageOfTheTurn() {
        var turn = AgentTurn(id: "t", prompt: "update both files", promptAt: Date())
        turn.items = [.message(id: "a", markdown: "I'll update both files"), .message(id: "b", markdown: "Done: both updated.")]
        #expect(turn.lastAnswerMarkdown == "Done: both updated.")
        #expect(AgentTurn(id: "u", prompt: "x", promptAt: Date()).lastAnswerMarkdown == nil)
    }
}

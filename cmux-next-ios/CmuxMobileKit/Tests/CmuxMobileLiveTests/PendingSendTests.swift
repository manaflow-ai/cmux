import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
/// Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
/// faster". A message sent in a chat whose Mac has not sent its tree yet (a relaunch, the link
/// still opening) is held for the chat's real source, as a send on a loaded chat rides out a blip
/// (`AcpmuxSessionSource.heldPromptWindow`). Before, it bounced at once: the draft came back with
/// "Connecting to <Mac>… Send again once the chat loads."
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct PendingSendTests {
    private func pending() -> PendingAgentSource {
        let summary = AgentSessionSummary(id: "s3", name: "chat", harness: "claude", agentName: "Claude", cwd: "~",
                                          workspaceTitle: "w", macName: "Studio", macID: "m1")
        return PendingAgentSource(summary: summary, cache: nil, keptKey: nil) { _ in }
    }

    private func prompt(_ text: String, id: String) -> AgentClientIntent {
        .prompt(text: text, attachments: [], steer: false, promptID: id, resend: false)
    }

    private static func isNotSent(_ event: AgentSessionEvent) -> Bool {
        if case .promptNotSent = event { true } else { false }
    }

    /// The prompt, then a cancel (which has nothing to act on and says so in both versions):
    /// the first event the chat gets is the cancel's, not the prompt coming back.
    @Test func aSendBeforeTheChatLoadsDoesNotBounce() async throws {
        let source = pending()
        var events = source.events().makeAsyncIterator()
        source.send(prompt("hello", id: "p1"))
        source.send(.cancel)
        let first = await events.next()
        #expect(first.map(Self.isNotSent) == false, "the draft came back at once: \(String(describing: first))")
    }

}
#endif

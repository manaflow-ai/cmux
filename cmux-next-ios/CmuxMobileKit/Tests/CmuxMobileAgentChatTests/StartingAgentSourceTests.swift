import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A chat whose workspace this phone is still creating (New Task, New Agent Chat) says it is
/// starting, names its agent only when it has one, and hands back what is sent meanwhile.
@MainActor
@Suite struct StartingAgentSourceTests {
    func summary(harness: String, agent: String) -> AgentSessionSummary {
        AgentSessionSummary(id: "new-1-t1", name: "New session", harness: harness, agentName: agent, cwd: "~/p",
                            workspaceTitle: "w", macName: "Mac")
    }

    /// A source whose "starting" note goes away later, as the hub forgets a session once its
    /// history attaches.
    final class FlippingSource: AgentSessionSource {
        let summary: AgentSessionSummary
        var starting = true
        init(summary: AgentSessionSummary) { self.summary = summary }
        var isStarting: Bool { starting }
        var loadsHistory: Bool { true }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    /// Live run 9: the chat read "Loading chat…" for a frame between "Starting Fake…" and the
    /// reply, because the store read the hub's note on each draw and the note was dropped first.
    @Test func theStoreKeepsTheStartingStateItWasMadeWith() {
        let source = FlippingSource(summary: summary(harness: "claude", agent: "Claude"))
        let store = AgentChatStore(source: source)
        source.starting = false
        #expect(store.isStarting)
        #expect(!AgentChatStore(source: source).isStarting)
    }

    /// Live run 9 (New Agent Chat): the Mac's default agent is not named yet; its placeholder
    /// tab is "Agent Chat", which is not an agent's name.
    @Test func theDefaultAgentIsNotNamed() {
        #expect(AgentChatStore.startingText(summary(harness: "claude", agent: "Claude")) == "Starting Claude…")
        #expect(AgentChatStore.startingText(summary(harness: "", agent: "Agent Chat")) == "Starting chat…")
    }

    @Test func aSendWhileStartingComesBackWithWhy() async {
        let source = StartingAgentSource(summary: summary(harness: "", agent: "Agent Chat"))
        var events = source.events().makeAsyncIterator()
        source.send(.prompt(text: "hi early", attachments: [], steer: false, promptID: "p1", resend: false))
        guard case .promptNotSent(let text, _, let id, let reason) = await events.next() else {
            Issue.record("the prompt was not handed back")
            return
        }
        #expect(text == "hi early" && id == "p1")
        #expect(reason == "The chat is still starting. Send again in a moment.")
    }
}

/// A New Task chat whose first message is on its way stays "starting" until the message shows
/// (fourth verifier: a frame of "What should Fake do?" came between the two).
@MainActor
@Suite struct AwaitsFirstPromptTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "t", name: "New session", harness: "claude", agentName: "Claude", cwd: "~/p",
                                          workspaceTitle: "w", macName: "Mac")
        var inFlight = true
        var awaitsFirstPrompt: Bool { inFlight }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    /// Live run 12: a task that never left the phone (the Mac's agent server went away) left its
    /// chat on "Starting <agent>…" for good. Once its send is over, a chat whose Mac is unreachable
    /// says it is connecting.
    @Test func aChatWhoseMacDroppedSaysConnectingOnceItsSendIsOver() {
        final class Dropped: AgentSessionSource {
            let summary = AgentSessionSummary(id: "t", name: "New session", harness: "claude", agentName: "Claude", cwd: "~/p",
                                              workspaceTitle: "w", macName: "Mac")
            var inFlight = true
            var awaitsFirstPrompt: Bool { inFlight }
            var isOffline: Bool { true }
            var isStarting: Bool { true }
            var loadsHistory: Bool { true }
            func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
            func send(_ intent: AgentClientIntent) {}
        }
        let source = Dropped()
        let store = AgentChatStore(source: source)
        #expect(store.loadingText == "Starting Claude…")
        source.inFlight = false
        #expect(store.loadingText == "Connecting to Mac…")
    }

    @Test func theChatStaysStartingUntilItsFirstSendEnds() {
        let source = Source()
        let store = AgentChatStore(source: source)
        #expect(store.awaitsFirstPrompt)
        // The send failed (or its turn ended): the chat is what it is, the composer has the draft.
        source.inFlight = false
        #expect(!store.awaitsFirstPrompt)
    }
}

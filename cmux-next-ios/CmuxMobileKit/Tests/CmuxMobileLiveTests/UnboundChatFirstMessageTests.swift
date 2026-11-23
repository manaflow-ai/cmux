#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Leo 2026-11-22: "figure out the fucking right behaviour we want, perfect it." A chat tab the
/// Mac opened that has no session yet told the person to send its first message from the Mac.
/// Now the phone's first message starts it, and the chat streams in the same store.
@MainActor
@Suite struct UnboundChatFirstMessageTests {
    func summary(harness: String = "agent", agent: String = "Agent") -> AgentSessionSummary {
        AgentSessionSummary(id: "tab-7", name: "New chat", harness: harness, agentName: agent, cwd: "/Users/me/p",
                            workspaceTitle: "w", macName: "cosmic-gray")
    }

    /// The started session: records what it was sent and replays one reply to every reader.
    final class Started: AgentSessionSource {
        let summary: AgentSessionSummary
        var sent: [AgentClientIntent] = []
        var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []
        init(summary: AgentSessionSummary) { self.summary = summary }
        func events() -> AsyncStream<AgentSessionEvent> {
            let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
            continuations.append(continuation)
            return stream
        }
        func send(_ intent: AgentClientIntent) {
            sent.append(intent)
            for continuation in continuations { continuation.yield(.turnStarted(turnId: "t1", at: Date())) }
        }
    }

    func prompt(_ text: String, _ id: String) -> AgentClientIntent {
        .prompt(text: text, attachments: [], steer: false, promptID: id, resend: false)
    }

    @Test func theFirstMessageStartsTheChatOnceAndEverythingSentMeanwhileFollowsInOrder() async throws {
        let started = Started(summary: summary(harness: "claude", agent: "Claude"))
        final class Count { var starts = 0 }
        let count = Count()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let source = UnboundAgentSource(summary: summary(), start: {
            count.starts += 1
            for await _ in gate { break }
            return started
        })
        var events = source.events().makeAsyncIterator()
        #expect(!source.awaitsFirstPrompt)

        source.send(prompt("first", "p1"))
        #expect(source.awaitsFirstPrompt, "it says Starting <agent>… while the session starts")
        source.send(prompt("second", "p2"))
        open.yield()
        for _ in 0..<10_000 where source.started == nil { await Task.yield() }

        #expect(count.starts == 1)
        #expect(started.sent.count == 2)
        guard case .prompt(let first, _, _, _, _) = started.sent[0], case .prompt(let second, _, _, _, _) = started.sent[1] else {
            Issue.record("not the prompts")
            return
        }
        #expect(first == "first" && second == "second")
        source.send(prompt("third", "p3"))
        #expect(started.sent.count == 3, "once started it is the session's source")
        guard case .turnStarted = await events.next() else {
            Issue.record("the reader made before the start does not follow the session")
            return
        }
    }

    @Test func aStartThatFailsGivesTheDraftBackWithWhy() async {
        struct Refused: LocalizedError { var errorDescription: String? { "cosmic-gray didn't answer. Not sent." } }
        let source = UnboundAgentSource(summary: summary(), start: { throw Refused() })
        var events = source.events().makeAsyncIterator()
        source.send(prompt("hi", "p1"))
        guard case .promptNotSent(let text, _, let id, let reason) = await events.next() else {
            Issue.record("the prompt was not handed back")
            return
        }
        #expect(text == "hi" && id == "p1")
        #expect(reason.contains("didn't answer"))
        #expect(!source.awaitsFirstPrompt)
    }

    /// A chat whose Mac has not sent its tree yet: messages sent meanwhile wait on one
    /// resolution and go to the chat's session in the order sent (they used to come back with
    /// "Send again once the chat loads", and then each resolved on its own, out of order).
    @Test func messagesSentBeforeTheTreeWaitOnOneResolutionAndGoInOrder() async {
        let started = Started(summary: summary(harness: "claude", agent: "Claude"))
        final class Count { var resolves = 0 }
        let count = Count()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let source = PendingAgentSource(summary: summary(), cache: nil, keptKey: nil, resolve: {
            count.resolves += 1
            for await _ in gate { break }
            return started
        }, onKept: { _ in })
        var events = source.events().makeAsyncIterator()
        source.send(prompt("first", "p1"))
        source.send(prompt("second", "p2"))
        source.send(prompt("third", "p3"))
        open.yield()
        for _ in 0..<10_000 where source.resolved == nil { await Task.yield() }

        #expect(count.resolves == 1, "one resolution serves every early message")
        #expect(started.sent.map(Self.text) == ["first", "second", "third"])
        source.send(prompt("fourth", "p4"))
        #expect(started.sent.count == 4, "once resolved it sends straight to the session")
        guard case .turnStarted = await events.next() else {
            Issue.record("the reader made before the tree does not follow the session")
            return
        }
    }

    @Test func aResolutionThatFailsGivesEveryEarlyDraftBack() async {
        struct Refused: LocalizedError { var errorDescription: String? { "cosmic-gray didn't answer. Not sent." } }
        let source = PendingAgentSource(summary: summary(), cache: nil, keptKey: nil, resolve: { throw Refused() },
                                        onKept: { _ in })
        var events = source.events().makeAsyncIterator()
        source.send(prompt("one", "p1"))
        source.send(prompt("two", "p2"))
        var back: [String] = []
        for _ in 0..<2 {
            guard case .promptNotSent(let text, _, _, let reason) = await events.next() else { break }
            #expect(reason.contains("didn't answer"))
            back.append(text)
        }
        #expect(back == ["one", "two"])
    }

    static func text(_ intent: AgentClientIntent) -> String {
        if case .prompt(let text, _, _, _, _) = intent { return text }
        return ""
    }

    /// The empty state said "What should Agent do?": an unbound tab with no harness is the
    /// Mac's default agent, which the chat now names.
    @Test func aTabWithNoHarnessNamesTheMacsDefaultAgent() async {
        let claude = AgentHarnessChoice(id: "claude", name: "Claude Code", family: "claude", isDefault: true)
        let source = UnboundAgentSource(summary: summary(), start: nil, nameAgent: { claude })
        let store = AgentChatStore(source: source)
        for _ in 0..<10_000 where store.summary.agentName == "Agent" { await Task.yield() }
        #expect(store.summary.agentName == "Claude")
        #expect(store.summary.harness == "claude")
    }
}
#endif

#if os(iOS)
import Foundation
import Observation
import Testing
@testable import CmuxMobileAgentChat

/// The composer's `@` candidates never tie typing to the Mac's output (Leo, 2026-11-22: "it
/// kinda seems like my ios typing inside the composer on ios is somehow coupled to the mac's
/// cpu or connection?"): reading them observes nothing, so streamed frames never re-render the
/// composer, and the transcript is rescanned at most once per `mentionRefresh`.
@MainActor
@Suite struct MentionArtifactsTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    private func turn(_ store: AgentChatStore, _ id: String, _ prompt: String) {
        store.apply(.userMessage(text: prompt, promptId: "p-\(id)", turnId: id, attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: id, at: Date()))
        store.apply(.turnResult(turnId: id, status: .completed, errorText: nil, at: Date()))
    }

    /// `onChange` is a `@Sendable` closure under Swift 6, so what it sets must be Sendable.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var fired: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test func readingTheCandidatesObservesNothing() {
        let store = AgentChatStore(source: Recorder())
        turn(store, "t1", "open Sources/App.swift")
        let flag = Flag()
        withObservationTracking { _ = store.mentionArtifacts() } onChange: { flag.fired = true }
        turn(store, "t2", "and README.md")
        #expect(!flag.fired, "a streamed change re-rendered whoever read the @ candidates")

        // What it replaced did observe the transcript.
        let tracked = Flag()
        withObservationTracking { _ = store.artifacts } onChange: { tracked.fired = true }
        turn(store, "t3", "then Package.swift")
        #expect(tracked.fired)
    }

    @Test func aChangingTranscriptIsRescannedAtMostOnceASecond() {
        let store = AgentChatStore(source: Recorder())
        let start = ContinuousClock.now
        turn(store, "t1", "open Sources/App.swift")
        let first = store.mentionArtifacts(now: start).generation
        #expect(store.mentionArtifacts(now: start).generation == first, "an unchanged transcript is not rescanned")
        turn(store, "t2", "and README.md")
        #expect(store.mentionArtifacts(now: start + .milliseconds(500)).generation == first, "rescanned within the second")
        let later = store.mentionArtifacts(now: start + AgentChatStore.mentionRefresh + .milliseconds(1)).generation
        #expect(later != first, "the change shows once the second is up")
    }
}
#endif

#if os(iOS)
import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Reads whose only answer is yes happen again on their own (Leo, 2026-11-22: "vacuous
/// decisions like that should be just done"): Replay and Copy read again after a dropped
/// link, and say a deterministic "unavailable" once.
@MainActor
@Suite struct ChatAutoRetryTests {
    struct Dropped: Error {}

    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s1", name: "S", harness: "claude", agentName: "Claude", cwd: "/w",
                                          workspaceTitle: "w", macName: "Studio", macID: "mac")
        var offline = false
        /// Errors the next reads throw, in order; empty: the read succeeds.
        var failures: [any Error] = []
        var reads = 0
        var isOffline: Bool { offline }
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
        private func next() throws {
            reads += 1
            if !failures.isEmpty { throw failures.removeFirst() }
        }
        func replayRecording() async throws -> AgentReplayRecording {
            try next()
            return AgentReplayRecording(steps: [], truncated: false)
        }
        func sessionDetails() async throws -> AgentSessionDetails {
            try next()
            return AgentSessionDetails(name: "fix-tests", sessionID: "acpmux-1", harnessSessionID: "h-9", cwd: "/w", host: "Studio",
                                       status: AgentSessionStatus(harness: "claude", fields: []))
        }
    }

    @Test func replaySaysANoFromTheMacOnceAndRetriesADroppedLink() async {
        let source = Source()
        let store = AgentChatStore(source: source)
        let player = ChatReplayPlayer()

        source.failures = [AgentFeatureUnavailable("This chat has no recorded history to replay.")]
        await player.load(store)
        #expect(player.state == .unavailable("This chat has no recorded history to replay."))
        #expect(!player.state.isFailed)

        // The live source wraps a dropped link as unavailable too; offline, it is transient.
        source.offline = true
        source.failures = [AgentFeatureUnavailable("Agents on Studio aren't connected.")]
        await player.load(store)
        #expect(player.state.isFailed)

        source.offline = false
        await player.load(store)
        #expect(player.state == .empty)
    }

    @Test func copyReadsAgainAfterADroppedLink() async throws {
        let source = Source()
        let store = AgentChatStore(source: source)
        let quick = AutoRetryBackoff(first: .milliseconds(1), cap: .milliseconds(2))
        source.failures = [Dropped()]
        let value = try await ChatCopyChoicesSheet.read(.agentName, store: store, backoff: quick)
        #expect(value == "fix-tests")
        #expect(source.reads == 2)
    }

    @Test func copySaysAMissingValueAtOnce() async {
        let source = Source()
        let store = AgentChatStore(source: source)
        let quick = AutoRetryBackoff(first: .milliseconds(1), cap: .milliseconds(2))
        source.failures = [AgentFeatureUnavailable("Session details are unavailable for this chat.")]
        await #expect(throws: AgentFeatureUnavailable.self) {
            _ = try await ChatCopyChoicesSheet.read(.agentName, store: store, backoff: quick)
        }
        #expect(source.reads == 1)
    }

    @Test func copyStopsAfterItsAttempts() async {
        let source = Source()
        let store = AgentChatStore(source: source)
        let quick = AutoRetryBackoff(first: .milliseconds(1), cap: .milliseconds(2))
        source.failures = [Dropped(), Dropped(), Dropped(), Dropped()]
        await #expect(throws: Dropped.self) {
            _ = try await ChatCopyChoicesSheet.read(.agentName, store: store, backoff: quick)
        }
        #expect(source.reads == 3)
    }
}
#endif

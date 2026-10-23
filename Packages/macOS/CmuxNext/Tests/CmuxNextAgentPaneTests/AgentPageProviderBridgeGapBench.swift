import CmuxNextPages
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Fixed-size bridge-gap measurement for the PR receipt. The focused fleet filter runs it only
/// when a receipt is requested; the same source runs on the parent and fixed final heads.
@Suite(.serialized)
@MainActor
struct AgentPageProviderBridgeGapBench {
    private static let eventCount = 1_024

    private final class Received {
        var events: [JSONValue] = []
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    @Test func fixedBridgeGapPublishesAndReplays() async throws {
        let provider = AgentPageProvider { _ in nil }
        let publishStart = ContinuousClock.now
        for index in 0..<Self.eventCount { provider.publish(.command("bridge-gap-\(index)")) }
        let publishMilliseconds = Self.milliseconds(publishStart.duration(to: ContinuousClock.now))

        let received = Received()
        let subscribeStart = ContinuousClock.now
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                         context: PageCallContext(page: PageDescriptor.agent.id)) { event in
            received.events.append(event)
        }
        await Self.settle()
        let replayMilliseconds = Self.milliseconds(subscribeStart.duration(to: ContinuousClock.now))
        subscription.cancel()

        print("AGENT-PAGE-BENCH events=\(Self.eventCount) publish_main_ms=\(String(format: \"%.3f\", publishMilliseconds)) replay_window_ms=\(String(format: \"%.3f\", replayMilliseconds)) delivered=\(received.events.count)")
    }
}

import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS"] == "901"))
@MainActor
struct AgentPageProviderBridgeGapBench {
    private static let eventCount = 1_024

    private final class Received {
        var events: [JSONValue] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func append(_ event: JSONValue) {
            events.append(event)
            if let waiter, events.count >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }

        func waitForAll(_ count: Int) async {
            guard events.count < count else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter = (count, continuation)
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
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
            received.append(event)
        }
        await received.waitForAll(Self.eventCount)
        let replayMilliseconds = Self.milliseconds(subscribeStart.duration(to: ContinuousClock.now))
        subscription.cancel()

        #expect(received.events.count == Self.eventCount)
        print("AGENT-PAGE-BENCH events=\(Self.eventCount) publish_main_ms=\(String(format: "%.3f", publishMilliseconds)) replay_window_ms=\(String(format: "%.3f", replayMilliseconds)) delivered=\(received.events.count)")
    }
}

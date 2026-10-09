@testable import CmuxLink
import Foundation
import Testing

@Suite("Adaptive render credit")
struct RenderCreditTests {
    @Test("RTT preserves custom declared and directional render budgets", arguments: [8 * 1024, 1024 * 1024], [false, true])
    func customRenderBudget(budget: Int, promotedFromInput: Bool) async throws {
        let pair = try await SessionTestPair()
        let hostSession = try await pair.nextHostSession()
        let descriptor = ChannelDescriptor(
            stream: "custom-render", reliability: .reliableOrdered,
            priority: promotedFromInput ? .input : .render,
            budgetBytes: promotedFromInput ? nil : budget
        )
        let (channel, _) = try await pair.openPair(descriptor, hostSession: hostSession)
        if promotedFromInput {
            await channel.setSendPriority(.render, budgetBytes: budget)
        }
        await pair.network.reportRTT(.seconds(2))
        // The state event proves the RTT sample reached the session before
        // checking its send limit; no timer or transport jitter is involved.
        try await SessionTestPair.waitFor(pair.dialer) {
            if case .degraded(_, .highLatency) = $0 { true } else { false }
        }
        let record = try #require(await pair.dialer.channels[channel.id])
        #expect(await pair.dialer.effectiveBudget(for: record) == budget)
        await pair.shutdown()
    }

    @Test("keeps the baseline until RTT can fill a larger bounded window")
    func boundedRTTWindow() {
        let configuration = LinkConfiguration(
            renderCreditTargetBytesPerSecond: 2_500_000,
            maxRenderCreditBytes: 1 * 1024 * 1024
        )
        #expect(configuration.renderCreditBudget(for: nil) == 256 * 1024)
        #expect(configuration.renderCreditBudget(for: .milliseconds(80)) == 256 * 1024)
        #expect(configuration.renderCreditBudget(for: .milliseconds(200)) == 500_000)
        #expect(configuration.renderCreditBudget(for: .seconds(2)) == 1 * 1024 * 1024)
    }

    @Test("can disable adaptation and clamps pathological RTT without an integer overflow")
    func disabledAndPathological() {
        let disabled = LinkConfiguration(renderCreditTargetBytesPerSecond: nil)
        #expect(disabled.renderCreditBudget(for: .seconds(2)) == 256 * 1024)

        let bounded = LinkConfiguration(
            renderCreditTargetBytesPerSecond: 2_500_000,
            maxRenderCreditBytes: 512 * 1024
        )
        #expect(bounded.renderCreditBudget(for: .seconds(Int64.max)) == 512 * 1024)
    }
}

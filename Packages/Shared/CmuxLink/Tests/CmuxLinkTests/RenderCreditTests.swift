import CmuxLink
import Foundation
import Testing

@Suite("Adaptive render credit")
struct RenderCreditTests {
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

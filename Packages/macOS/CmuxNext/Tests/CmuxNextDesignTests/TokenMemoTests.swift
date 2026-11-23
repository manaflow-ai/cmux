import Foundation
import Observation
@testable import CmuxNextDesign
import Testing

/// `TokenMemo` (the composite design tokens a layout reads many times a frame): one compute until an input changes,
/// never a stale value, and a tracking caller that read a kept value still hears the change.
@MainActor @Suite(.serialized) struct TokenMemoTests {
    @Observable final class Input {
        var value = 1
    }

    nonisolated final class Fired: @unchecked Sendable {
        var count = 0
    }

    /// Lets the main queue run, so a drop's settling window closes.
    private func mainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    @Test func keepsTheValueUntilAnInputChanges() async {
        let input = Input(), memo = TokenMemo<Int>()
        var computes = 0
        let read = { memo.value { computes += 1; return input.value * 10 } }
        #expect(read() == 10 && read() == 10)
        #expect(computes == 1)

        input.value = 2
        // Before the main queue turns: fresh, not kept.
        #expect(read() == 20 && read() == 20)
        #expect(computes == 3)

        await mainTurn()
        #expect(read() == 20 && read() == 20)
        #expect(computes == 4)
    }

    @Test func aCallerThatReadAKeptValueHearsTheChange() async {
        let input = Input(), memo = TokenMemo<Int>()
        _ = memo.value { input.value }
        await mainTurn()
        let fired = Fired()
        let seen = withObservationTracking { memo.value { input.value } } onChange: { fired.count += 1 }
        #expect(seen == 1)
        input.value = 5
        #expect(fired.count == 1)
        #expect(memo.value { input.value } == 5)
    }

    @Test func aScopedDensityIsNeverKept() {
        let memo = TokenMemo<String>()
        #expect(memo.value { Metrics.tokens.id } == DesignSettings.shared.densityTokens.id)
        let scoped = DensityPreset.allCases.map(\.tokens).first { $0.id != DesignSettings.shared.densityTokens.id }!
        DensityTokens.$scoped.withValue(scoped) {
            #expect(memo.value { Metrics.tokens.id } == scoped.id)
        }
        #expect(memo.value { Metrics.tokens.id } == DesignSettings.shared.densityTokens.id)
    }
}

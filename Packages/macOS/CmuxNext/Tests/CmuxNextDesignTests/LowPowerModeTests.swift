@testable import CmuxNextDesign
import Testing

/// A Low Power Mode change reaches only the observers still registered when their turn comes. The
/// page pool's handler closes its spare (ending the spare's own observation); the spare's handler,
/// already in the change's list, then wrote a WebKit preference and could queue a re-show for a
/// closed web view, depending on which handler ran first.
@MainActor @Suite struct LowPowerModeTests {
    private final class Observers {
        var first: LowPowerModeObservation?
        var second: LowPowerModeObservation?
        var calls = 0
    }

    /// Each handler cancels the other, so whichever runs first, the other must not run.
    @Test func anObserverCancelledDuringAChangeIsNotCalled() {
        let mode = LowPowerMode(enabled: false)
        let observers = Observers()
        observers.first = mode.observe { [observers] _ in
            observers.calls += 1
            observers.second = nil
        }
        observers.second = mode.observe { [observers] _ in
            observers.calls += 1
            observers.first = nil
        }
        mode.override = true
        #expect(observers.calls == 1, "a handler ran after an earlier handler of the same change cancelled it")
    }

    @Test func everyRegisteredObserverHearsAChange() {
        let mode = LowPowerMode(enabled: false)
        var heard: [Bool] = []
        let first = mode.observe { heard.append($0) }
        let second = mode.observe { heard.append($0) }
        mode.override = true
        #expect(heard == [true, true])
        withExtendedLifetime((first, second)) {}
    }
}

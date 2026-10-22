@testable import CmuxNextBrowser
import Foundation
import Testing

/// Load progress in `BrowserTabStateMachine`: Chromium reports it per resource, so the state
/// (and the tab chrome that renders it) changes only for a visible step or the end of the load.
@Suite struct BrowserTabProgressTests {
    static func loading() -> BrowserTabStateMachine {
        var machine = BrowserTabStateMachine()
        _ = machine.apply(.started(BrowserNavigationID(rawValue: 1), url: URL(string: "https://example.com/")))
        return machine
    }

    @Test func aTinyRiseChangesNothing() {
        var machine = Self.loading()
        let start = machine.state.progress
        #expect(!machine.apply(.progress(start + 0.001)))
        #expect(machine.state.progress == start)
    }

    @Test func aVisibleStepIsShown() {
        var machine = Self.loading()
        #expect(machine.apply(.progress(0.5)))
        #expect(machine.state.progress == 0.5)
    }

    @Test func smallRisesAddUpToAStep() {
        var machine = Self.loading()
        let start = machine.state.progress
        var changes = 0
        for step in 1...30 where machine.apply(.progress(start + Double(step) * 0.001)) { changes += 1 }
        #expect(changes == 1)
        #expect(machine.state.progress >= start + BrowserTabStateMachine.progressStep)
    }

    @Test func theEndIsAlwaysShown() {
        var machine = Self.loading()
        _ = machine.apply(.progress(0.99))
        #expect(machine.apply(.progress(1)))
        #expect(machine.state.progress == 1)
    }

    @Test func progressNeverGoesBack() {
        var machine = Self.loading()
        _ = machine.apply(.progress(0.6))
        #expect(!machine.apply(.progress(0.3)))
        #expect(machine.state.progress == 0.6)
    }
}

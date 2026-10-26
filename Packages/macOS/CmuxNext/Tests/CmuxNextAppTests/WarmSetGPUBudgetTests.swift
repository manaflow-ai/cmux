import CmuxNextBridge
import CmuxNextCompat
import CmuxNextMemory
import Testing

/// p07-memory-037: the warm set grows only when hidden surfaces can let their GPU memory go, and the
/// surface ledger says which terminals are away (hidden, outside the keep-alive band).
@MainActor struct WarmSetGPUBudgetTests {
    /// The app's warm set at `level` (`AppServices.memoryPressureDidChange`).
    private func warm(_ level: MemoryPressureLevel, gib: UInt64, release: Bool) -> Int {
        let budget = SubsystemBudget.forMemory(physicalBytes: gib << 30, gpuResidentAvailable: release)
        return WarmSetBudget.at(level, normal: budget.warmTerminalSurfaces).terminalCapacity
    }

    @Test func theWarmSetGrowsOnlyWithTheGPURelease() {
        #expect(warm(.normal, gib: 16, release: true) == 16)
        // Without the release API, the size it had before: min(24, max(8, MiB / 64 / 48)).
        #expect(warm(.normal, gib: 16, release: false) == 8)
        #expect(warm(.normal, gib: 64, release: false) == 21)
        #expect(warm(.normal, gib: 8, release: false) == 8)
        #expect(warm(.normal, gib: 64, release: true) == 32)
    }

    @Test func pressureShrinksTheWarmSet() {
        #expect(warm(.critical, gib: 16, release: true) == 0)
        #expect(warm(.warning, gib: 16, release: true) == WarmSetBudget.warningCapacity)
        #expect(WarmSetBudget.at(.warning, normal: 4).terminalCapacity == 4)
        #expect(WarmSetBudget.at(.normal, normal: 16).terminalCapacity == 16)
    }

    @Test func theLedgerReportsTerminalsThatGoAwayAndComeBack() {
        var ledger = SurfaceLedger<String, Int>(capacity: 4)
        #expect(ledger.present("a", by: 1, presence: .visible).away.isEmpty, "a shown tab was never away")
        #expect(!ledger.isAway("a"))

        var effects = ledger.setPresence(.keepAlive, owner: 1)
        #expect(effects.away.isEmpty, "the keep-alive band is not away: \(effects.away)")
        #expect(effects.rendering == ["a": false])

        effects = ledger.setPresence(.hidden, owner: 1)
        #expect(effects.away == ["a": true])
        #expect(ledger.isAway("a"))

        effects = ledger.setPresence(.visible, owner: 1)
        #expect(effects.away == ["a": false])
        #expect(effects.rendering == ["a": true])
        #expect(!ledger.isAway("a"))

        effects = ledger.withdraw("a", by: 1)
        #expect(effects.away == ["a": true], "a tab no pane presents is away")
    }

    @Test func anEvictedTerminalIsNoLongerReportedAway() {
        var ledger = SurfaceLedger<String, Int>(capacity: 1)
        _ = ledger.present("a", by: 1, presence: .hidden)
        #expect(ledger.isAway("a"))
        let effects = ledger.setCapacity(0)
        #expect(effects.evicted == ["a"])
        #expect(effects.away["a"] == nil)
        #expect(!ledger.isAway("a"))
    }
}

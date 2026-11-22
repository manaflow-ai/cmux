import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextCompat
import Testing

/// SWITCH FRAMES SF-2 (lead 2026-11-02 10:4xZ): memory pressure shrinks the warm set of hidden terminals in the
/// pressure event's own turn, as Chrome discards under pressure. The 2x measurement (cmux23/cmux24) also showed it in
/// the app: a warning left 6 hidden + 1 shown live terminals in the same call; critical left only the shown one.
@MainActor @Suite(.serialized) struct WarmSetPressureEvictionTests {
    /// Memory pressure shrinks the warm set in the event's own turn: hidden terminals past the new budget are evicted
    /// before `memoryPressureDidChange` returns; critical keeps none.
    @Test func aMemoryPressureEventEvictsTheWarmSetAtOnce() {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let normal = services.cache.warmBudget.terminalCapacity
        let hidden = (0..<max(normal, 12)).map { "hidden-\($0)" }
        // Shown, then their panes leave the screen: hidden, kept warm up to the budget.
        services.cache.ledger = Self.hidden(hidden, capacity: normal)
        let warmBefore = hidden.filter(services.cache.ledger.isRetained).count
        #expect(warmBefore == min(hidden.count, normal), "setup: \(warmBefore) warm of \(hidden.count), budget \(normal)")

        services.memoryPressureDidChange(.warning)
        let warning = WarmSetBudget.current(pressure: .warning).terminalCapacity
        #expect(services.cache.warmBudget.terminalCapacity == warning)
        #expect(hidden.filter(services.cache.ledger.isRetained).count <= warning, "a warning left more hidden terminals warm than its budget")

        services.memoryPressureDidChange(.critical)
        #expect(hidden.filter(services.cache.ledger.isRetained).isEmpty, "critical pressure kept hidden terminals warm")
        services.memoryPressureDidChange(.normal)
        #expect(services.cache.warmBudget.terminalCapacity == normal)
    }

    /// A ledger of `capacity` where each key was shown by its own owner and every owner then left: the keys are
    /// hidden and LRU-retained up to the capacity.
    static func hidden(_ keys: [String], capacity: Int) -> SurfaceLedger<String, ObjectIdentifier> {
        var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: capacity)
        let owners = keys.map { _ in NSObject() }
        for (key, owner) in zip(keys, owners) { _ = ledger.present(key, by: ObjectIdentifier(owner), ownerVisible: true) }
        for owner in owners { _ = ledger.removeOwner(ObjectIdentifier(owner)) }
        return ledger
    }
}

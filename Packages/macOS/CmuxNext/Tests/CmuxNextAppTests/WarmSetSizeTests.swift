import AppKit
import CmuxNextBridge
import CmuxNextCompat
import Testing

/// SWITCH FRAMES (STATUS 8158, 8927; lead order on 8158): under W1 HEAVY each switch between 12-pane workspaces made 12
/// terminal sessions again (about 16 ms of init each on the main thread, then 220 ms of empty panes), because the warm
/// set held 8 hidden terminals: 1/64 of physical memory at 48 MB a terminal, clamped to 8...24. The warm set holds the
/// visible panes of the last 2 to 3 workspaces instead, sized from physical memory as Chrome sizes its renderer limit:
/// a switch among them makes no session.
@MainActor @Suite struct WarmSetSizeTests {
    static let gib: UInt64 = 1 << 30

    /// 12 hidden keys per workspace, `workspaces` of them, shown in turn and then all hidden by a 13th: which stay warm.
    static func warmAfterCycling(workspaces: Int, capacity: Int) -> (warm: Int, of: Int) {
        var ledger = SurfaceLedger<String, ObjectIdentifier>(capacity: capacity)
        var keys: [String] = []
        for w in 0..<workspaces {
            let owners = (0..<12).map { _ in NSObject() }
            for (p, owner) in owners.enumerated() {
                let key = "ws\(w)-p\(p)"
                keys.append(key)
                _ = ledger.present(key, by: ObjectIdentifier(owner), ownerVisible: true)
            }
            for owner in owners { _ = ledger.removeOwner(ObjectIdentifier(owner)) }
        }
        return (keys.filter(ledger.isRetained).count, keys.count)
    }

    @Test func the16GBMacKeepsTheLastTwoTwelvePaneWorkspacesWarm() {
        let capacity = WarmSetBudget.forMemory(physicalBytes: 16 * Self.gib, pressure: .normal).terminalCapacity
        let (warm, of) = Self.warmAfterCycling(workspaces: 2, capacity: capacity)
        #expect(warm == of, "a 16 GB Mac keeps \(warm) of the last 2 workspaces' \(of) panes warm (capacity \(capacity))")
    }

    @Test func the24GBMacKeepsTheLastThreeTwelvePaneWorkspacesWarm() {
        let capacity = WarmSetBudget.forMemory(physicalBytes: 24 * Self.gib, pressure: .normal).terminalCapacity
        let (warm, of) = Self.warmAfterCycling(workspaces: 3, capacity: capacity)
        #expect(warm == of, "a 24 GB Mac keeps \(warm) of the last 3 workspaces' \(of) panes warm (capacity \(capacity))")
    }

    /// The bound follows memory, with a floor for small Macs and a ceiling (O(warm) work per switch), and pressure
    /// still shrinks it as before.
    @Test func theWarmSetStaysBoundedAndPressureStillShrinksIt() {
        let small = WarmSetBudget.forMemory(physicalBytes: 4 * Self.gib, pressure: .normal).terminalCapacity
        let huge = WarmSetBudget.forMemory(physicalBytes: 512 * Self.gib, pressure: .normal).terminalCapacity
        #expect(small >= 8, "a 4 GB Mac keeps \(small)")
        #expect(huge <= 64, "a 512 GB Mac keeps \(huge)")
        #expect(WarmSetBudget.forMemory(physicalBytes: 24 * Self.gib, pressure: .warning).terminalCapacity == 6)
        #expect(WarmSetBudget.forMemory(physicalBytes: 24 * Self.gib, pressure: .critical).terminalCapacity == 0)
    }
}

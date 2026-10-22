import Testing
@testable import CmuxNextDaemon

/// u9415: a tab asked for in the Home dock (a pinned column that takes no tabs) goes beside it.
struct DockTabHostTests {
    private let dock = PaneID(rawValue: 1), first = PaneID(rawValue: 2), second = PaneID(rawValue: 3)

    private func columns(pinned: Bool = true, allowsTabs: Bool = false, beside: [PaneID]) -> [ColumnSnapshot] {
        let home = ColumnSnapshot(id: ColumnID(rawValue: 10), width: 0.3, layout: .leaf(dock),
                                  dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: pinned, allowsTabs: allowsTabs))
        return [home] + beside.enumerated().map { ColumnSnapshot(id: ColumnID(rawValue: UInt64(11 + $0.offset)), width: 0.5, layout: .leaf($0.element)) }
    }

    @Test func aTabAskedForInTheDockGoesToTheFocusedPaneBesideIt() {
        let host = DockTabHost.resolve(dock, columns: columns(beside: [first, second]), order: [dock, first, second],
                                       active: second, focusedAt: { _ in 0 })
        #expect(host == .beside(second))
    }

    @Test func withTheDockFocusedTheMostRecentlyFocusedPaneTakesIt() {
        let recency: [PaneID: UInt64] = [first: 4, second: 9]
        let host = DockTabHost.resolve(dock, columns: columns(beside: [first, second]), order: [dock, first, second],
                                       active: dock, focusedAt: { recency[$0] ?? 0 })
        #expect(host == .beside(second))
    }

    @Test func equalRecencyKeepsLayoutOrder() {
        let host = DockTabHost.resolve(dock, columns: columns(beside: [first, second]), order: [dock, first, second],
                                       active: dock, focusedAt: { _ in 0 })
        #expect(host == .beside(first))
    }

    @Test func aLoneDockHasNoPaneBesideIt() {
        let host = DockTabHost.resolve(dock, columns: columns(beside: []), order: [dock], active: dock, focusedAt: { _ in 0 })
        #expect(host == .alone)
    }

    @Test func aPaneOutsideTheDockAndADockWithAllowTabsTakeTabs() {
        #expect(DockTabHost.resolve(first, columns: columns(beside: [first]), order: [dock, first], active: dock,
                                    focusedAt: { _ in 0 }) == .takesTabs)
        #expect(DockTabHost.resolve(dock, columns: columns(allowsTabs: true, beside: [first]), order: [dock, first], active: dock,
                                    focusedAt: { _ in 0 }) == .takesTabs)
        #expect(DockTabHost.resolve(dock, columns: columns(pinned: false, beside: [first]), order: [dock, first], active: dock,
                                    focusedAt: { _ in 0 }) == .takesTabs)
        #expect(DockTabHost.resolve(dock, columns: [], order: [dock], active: dock, focusedAt: { _ in 0 }) == .takesTabs)
    }
}

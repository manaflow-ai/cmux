@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-18: quick Cmd-N presses with new workspaces at the top left the rows out of order,
/// "because it opens too slowly". Each new workspace is placed before the row the sidebar shows
/// first. When that row is the previous new workspace, whose own placement the home daemon has
/// not applied yet, it has no personal position, and the placement fell back to after the
/// window's last row: the new workspace went to the bottom.
struct NewWorkspacePlacementRaceTests {
    @Test func aSlotBeforeAnUnplacedRowTakesTheNextPlacedRowsPosition() {
        // w47 shows first (its placement is in flight); w46 and w45 are placed.
        let plan = SidebarSection.personalPlacements(moving: ["w48"], localIndex: 0, shown: ["w47", "w46", "w45"],
                                                     rowed: ["home", "w46", "w45"])
        #expect(plan == [.init(key: "w48", index: 1)], "w48 goes right before w46, not after w45")
    }

    @Test func placedRowsKeepTheirAnchor() {
        #expect(SidebarSection.globalIndex(localIndex: 1, local: ["a", "b", "c"], global: ["x", "a", "b", "c"]) == 2)
        #expect(SidebarSection.globalIndex(localIndex: 3, local: ["a", "b", "c"], global: ["x", "a", "b", "c"]) == 4)
        #expect(SidebarSection.globalIndex(localIndex: 0, local: [], global: ["x"]) == 1)
    }

    /// Five quick creates at the top, each placement applied by the daemon only after the next
    /// one was planned (the sidebar already shows the earlier rows at the top).
    @Test func quickCreatesAtTheTopEndInPressOrderWhenEachPlacementLandsLate() {
        var order = ["w1"]
        var inFlight: [SidebarSection.PersonalPlacement] = []
        for press in 2...6 {
            let shown = (1..<press).reversed().map { "w\($0)" }
            inFlight += SidebarSection.personalPlacements(moving: ["w\(press)"], localIndex: 0, shown: shown, rowed: order)
            if inFlight.count > 1 { Self.apply(inFlight.removeFirst(), to: &order) }
        }
        inFlight.forEach { Self.apply($0, to: &order) }
        #expect(order == ["w6", "w5", "w4", "w3", "w2", "w1"])
    }

    /// `workspace.place`: the index counts after the key itself is removed.
    private static func apply(_ placement: SidebarSection.PersonalPlacement, to order: inout [String]) {
        order.removeAll { $0 == placement.key }
        order.insert(placement.key, at: min(placement.index, order.count))
    }
}

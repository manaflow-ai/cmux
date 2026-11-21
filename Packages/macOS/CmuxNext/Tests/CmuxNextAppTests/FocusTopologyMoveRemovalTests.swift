import CmuxNextFocus
import Testing

/// A move that empties its pane removes that pane with its tab carried to the destination: the tab
/// stays in the topology, so the reducer keeps its browser focus mode (router review F1 on #37735).
@Suite struct FocusTopologyMoveRemovalTests {
    private static let topology = FocusTopology(
        workspace: "w",
        panes: [.init(id: "left", tabs: [.init(id: "a", kind: .terminal)]), .init(id: "right", tabs: [.init(id: "b", kind: .browser)])],
        screens: [[.init(id: "c1", panes: ["left"]), .init(id: "c2", panes: ["right"])]]
    )

    @Test func theMovedTabLandsInItsDestination() {
        let after = Self.topology.removing(pane: "right", carrying: { tab in tab.id == "b" ? (pane: "left", tab: tab) : nil })
        #expect(!after.contains(pane: "right"))
        #expect(after.pane("left")?.tabs.map(\.id) == ["a", "b"])
        #expect(after.pane("left")?.tab("b")?.kind == .browser)
    }

    @Test func anUnknownDestinationDropsThePaneAsBefore() {
        #expect(Self.topology.removing(pane: "right", carrying: { tab in tab.id == "b" ? (pane: "gone", tab: tab) : nil }) == Self.topology.removing(pane: "right"))
    }
}

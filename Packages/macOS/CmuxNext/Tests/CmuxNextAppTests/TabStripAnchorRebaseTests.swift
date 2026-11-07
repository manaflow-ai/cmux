import CmuxNextTabs
import Testing

/// `TabStripModel.anchor(replacing:newTab:staying:opened:)`: the tab a new tab goes after once the tab it was
/// placed after closed while it was made (Leo 2026-11-05, the close/create shuffle). The nearest staying tab left
/// of the closed anchor, from the strip, from the new tab's place, or from the pane's order when the open began.
@MainActor struct TabStripAnchorRebaseTests {
    private static func strip(_ ids: [String]) -> TabStripModel {
        TabStripModel(tabs: ids.map { TabItem(id: TabID($0), title: $0) })
    }

    private static func ids(_ names: [String]) -> Set<TabID> { Set(names.map { TabID($0) }) }

    @Test func theStripStillShowsTheAnchor() {
        let model = Self.strip(["a", "b", "N", "c"])
        #expect(model.anchor(replacing: TabID("b"), newTab: Self.ids(["N"]), staying: Self.ids(["a", "c"])) == TabID("a"))
    }

    @Test func theStripDroppedTheAnchorAndShowsTheNewTab() {
        let model = Self.strip(["a", "N", "c"])
        #expect(model.anchor(replacing: TabID("b"), newTab: Self.ids(["N"]), staying: Self.ids(["a", "c"])) == TabID("a"))
    }

    /// An open with no stand-in (a daemon without optimistic creates): the strip shows neither the anchor nor
    /// the new tab, so the pane's order when the open began says where the anchor was.
    @Test func noStandInFallsBackToTheOrderWhenTheOpenBegan() {
        let model = Self.strip(["a", "c"])
        let opened = ["a", "b", "c"].map { TabID($0) }
        #expect(model.anchor(replacing: TabID("b"), newTab: Self.ids(["N"]), staying: Self.ids(["a", "c"]), opened: opened) == TabID("a"))
    }

    /// The first tab closed: the new tab goes first (nil, the first unpinned slot).
    @Test func noStayingTabLeftOfTheAnchorIsTheStart() {
        let model = Self.strip(["a", "N", "c"])
        #expect(model.anchor(replacing: TabID("a"), newTab: Self.ids(["N"]), staying: Self.ids(["c"])) == nil)
    }
}

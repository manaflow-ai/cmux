import CmuxNextTabs
import Testing

/// A pane's row shows as no band over its chat only while the pane holds one tab (Leo, 2026-11-03:
/// "isn't it kinda arbitrary anyway if you literally only have one tab there?"); two or more keep it.
@MainActor
struct TabStripHoldsOneTabTests {
    @Test func onlyOneTabIsSolo() {
        let tab = { (name: String) in TabItem(id: TabID(name), title: name) }
        #expect(!TabStripModel().holdsOneTab)
        #expect(TabStripModel(tabs: [tab("a")]).holdsOneTab)
        let model = TabStripModel(tabs: [tab("a"), tab("b")])
        #expect(!model.holdsOneTab)
        model.tabs.removeLast()
        #expect(model.holdsOneTab)
    }
}

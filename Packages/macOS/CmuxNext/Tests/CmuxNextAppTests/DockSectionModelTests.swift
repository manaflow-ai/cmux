@testable import CmuxNextApp
import CmuxNextLayout
import Testing

/// The Dock section's rows: the docked columns of a window's shown screen, each named by its
/// selected tab.
@MainActor @Suite
struct DockSectionModelTests {
    @Test func theDockSectionListsTheShownScreensDockedColumns() {
        let model = DockSectionModel()
        let scrolling = LayoutColumn(id: "c1", root: .leaf("p1"))
        let docked = LayoutColumn(id: "c2", root: .leaf("p2"), dock: DockColumn(edge: .left))
        model.update(columns: [scrolling, docked]) { $0 == "p2" ? "notes" : nil }
        #expect(model.rows == [DockSectionRow(id: "c2", edge: .left, pane: "p2", title: "notes")])
    }
}

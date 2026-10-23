import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// The widths a New Column brings hold from its key's frame through the handoff, where the
/// daemon's column replaces the stand-in's under a new id, until the daemon's layout has them
/// (review 1 of PL-motion-core): no frame shows a column springing back to its old width.
@MainActor
struct NewColumnSizingHoldTests {
    final class Sent {
        var intents: [LayoutIntent] = []
    }

    /// A split-tree screen's lone column next to its two columns: `tree` holds p1, `new` holds p2.
    private static func columns(tree: ColumnID, width: Double, new: ColumnID) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "s", layout: .columns([LayoutColumn(id: tree, width: width, root: .leaf("p1")),
                                                           LayoutColumn(id: new, width: 0.5, root: .leaf("p2"))]))]
    }

    /// New Column on a split-tree screen with fixed widths: the lone column is 0.5 wide in every
    /// layout from the key's frame to the daemon's settled one. The stand-in's overlay leaves when
    /// the column settles, and the daemon's layout then has the tree column at full width until its
    /// width intent lands: it showed full width for a frame, then shrank again.
    @Test func theTreeColumnKeepsItsNewWidthThroughTheHandoff() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        model.followsDesignMetrics = false
        model.newColumnWidthModeOverride = .fixed
        model.defaultColumnWidthOverride = 0.5
        let sent = Sent()
        model.intentHandler = { intent in sent.intents.append(intent) }
        let treeWidth = { model.screens.first?.layout.column(containing: "p1")?.width }

        let request = model.prepareNewColumn(nextTo: "p1")
        #expect(request.width == 0.5)
        #expect(request.widthChanges.map { $0.width } == [0.5])
        let sizing = model.showNewColumnSizing(request)
        // The store's overlay: the stand-in's tree column and column.
        model.apply(screens: Self.columns(tree: "column:standin-tree", width: 0.5, new: "column:standin"))
        #expect(treeWidth() == 0.5)
        // The column settled: the daemon's layout under its ids, the tree column at full width.
        model.apply(screens: Self.columns(tree: "column:1", width: 1, new: "column:2"))
        #expect(treeWidth() == 0.5, "the lone column sprang back to full width at the handoff")

        model.commitNewColumnSizing(sizing)
        guard case .setColumnWidth(_, let pane, let width, let transaction, .ended)? = sent.intents.last else {
            Issue.record("no width intent after the column landed: \(sent.intents)")
            return
        }
        #expect(pane == "p1" && width == 0.5)
        #expect(sent.intents.count == 1)
        // A layout from before the width command still has full width.
        model.apply(screens: Self.columns(tree: "column:1", width: 1, new: "column:2"))
        #expect(treeWidth() == 0.5)
        model.settleTransaction(transaction)
        model.apply(screens: Self.columns(tree: "column:1", width: 0.5, new: "column:2"))
        #expect(treeWidth() == 0.5)
        // Settled: the daemon's width is the truth again, nothing holds it.
        model.apply(screens: Self.columns(tree: "column:1", width: 0.75, new: "column:2"))
        #expect(treeWidth() == 0.75)
    }

    /// Review 2 of PL-motion-core: the commit (the create's reply) came while the create was still
    /// in the store's log, and an unrelated layout (the store's overlay, its stand-in column at the
    /// new widths) matched the hold, which dropped it. When the create settled, the daemon's tree
    /// column showed at full width until the width echo arrived: the spring-back frame again. The
    /// hold now stays until its width command was answered and the store applied that answer.
    @Test func aCommitBeforeTheCreateSettlesKeepsTheHoldThroughAnUnrelatedLayout() throws {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        model.followsDesignMetrics = false
        model.newColumnWidthModeOverride = .fixed
        model.defaultColumnWidthOverride = 0.5
        let sent = Sent()
        model.intentHandler = { intent in sent.intents.append(intent) }
        let treeWidth = { model.screens.first?.layout.column(containing: "p1")?.width }

        let sizing = model.showNewColumnSizing(model.prepareNewColumn(nextTo: "p1"))
        model.apply(screens: Self.columns(tree: "column:standin-tree", width: 0.5, new: "column:standin"))
        // The create replied; its intent is still in the store's log (awaiting its records).
        model.commitNewColumnSizing(sizing)
        guard case .setColumnWidth(_, _, _, let transaction, .ended)? = sent.intents.last else {
            Issue.record("no width intent at the commit: \(sent.intents)")
            return
        }
        // An unrelated layout while the overlay still shows the stand-in at the new width.
        model.apply(screens: Self.columns(tree: "column:standin-tree", width: 0.5, new: "column:standin"))
        #expect(treeWidth() == 0.5)
        // The create settled: the daemon's tree column at full width, its width command not applied yet.
        model.apply(screens: Self.columns(tree: "column:1", width: 1, new: "column:2"))
        #expect(treeWidth() == 0.5, "the hold left on a match with the overlay: the column sprang back at the handoff")
        // The width command was answered and its events applied.
        model.settleTransaction(transaction)
        model.apply(screens: Self.columns(tree: "column:1", width: 0.5, new: "column:2"))
        #expect(treeWidth() == 0.5)
        model.apply(screens: Self.columns(tree: "column:1", width: 0.75, new: "column:2"))
        #expect(treeWidth() == 0.75, "the hold outlived its settled width command")
    }

    /// A refused New Column takes its widths back.
    @Test func aRefusedNewColumnTakesItsWidthsBack() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))], activeScreenID: "s",
                                focusedPane: "p1")
        model.followsDesignMetrics = false
        model.newColumnWidthModeOverride = .fixed
        model.defaultColumnWidthOverride = 0.5
        let sizing = model.showNewColumnSizing(model.prepareNewColumn(nextTo: "p1"))
        model.apply(screens: Self.columns(tree: "column:1", width: 1, new: "column:2"))
        #expect(model.screens.first?.layout.column(containing: "p1")?.width == 0.5)
        model.cancelNewColumnSizing(sizing)
        #expect(model.screens.first?.layout.column(containing: "p1")?.width == 1)
    }
}

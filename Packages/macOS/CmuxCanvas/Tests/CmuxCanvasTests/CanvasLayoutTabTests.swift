import Foundation
import Testing
@testable import CmuxCanvas

@Suite("CanvasLayout tabs")
struct CanvasLayoutTabTests {
    private func panelID() -> CanvasPanelID { CanvasPanelID(rawValue: UUID()) }

    private func singleTabPane(at x: Double = 0) -> CanvasPane {
        CanvasPane(
            id: CanvasPaneID(rawValue: UUID()),
            frame: CanvasRect(x: x, y: 0, width: 300, height: 200)
        )
    }

    @Test func singleTabPaneHostsItsFoundingPanel() {
        let pane = singleTabPane()
        #expect(pane.panelIds == [CanvasPanelID(rawValue: pane.id.rawValue)])
        #expect(pane.selectedPanelId.rawValue == pane.id.rawValue)
    }

    @Test func addPanelJoinsAndSelects() {
        var layout = CanvasLayout(panes: [singleTabPane(), singleTabPane(at: 400)])
        let destination = layout.paneIDs[0]
        let joining = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: joining.rawValue), frame: CanvasRect(x: 800, y: 0, width: 300, height: 200)))

        layout.addPanel(joining, toPane: destination)

        // The joining panel's old single-tab pane disappeared with it.
        #expect(layout.panes.count == 2)
        #expect(layout.pane(containing: joining) == destination)
        #expect(layout.selectedPanelId(in: destination) == joining)
        #expect(layout.panelIds(in: destination)?.count == 2)
    }

    @Test func addPanelAtIndexClampsAndOrders() {
        var layout = CanvasLayout(panes: [singleTabPane()])
        let destination = layout.paneIDs[0]
        let a = panelID()
        let b = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: a.rawValue), frame: CanvasRect(x: 400, y: 0, width: 300, height: 200)))
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: b.rawValue), frame: CanvasRect(x: 800, y: 0, width: 300, height: 200)))

        layout.addPanel(a, toPane: destination, at: 0, select: false)
        layout.addPanel(b, toPane: destination, at: 99, select: false)

        let founding = CanvasPanelID(rawValue: destination.rawValue)
        #expect(layout.panelIds(in: destination) == [a, founding, b])
        // select: false keeps the original selection.
        #expect(layout.selectedPanelId(in: destination) == founding)
    }

    @Test func removePanelMovesSelectionToNeighbor() {
        var layout = CanvasLayout(panes: [singleTabPane()])
        let destination = layout.paneIDs[0]
        let a = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: a.rawValue), frame: CanvasRect(x: 400, y: 0, width: 300, height: 200)))
        layout.addPanel(a, toPane: destination, select: true)

        let hostingPane = layout.removePanel(a)

        #expect(hostingPane == destination)
        #expect(layout.panes.count == 1)
        #expect(layout.selectedPanelId(in: destination) == CanvasPanelID(rawValue: destination.rawValue))
    }

    @Test func removingLastPanelRemovesPane() {
        var layout = CanvasLayout(panes: [singleTabPane()])
        let pane = layout.paneIDs[0]
        layout.removePanel(CanvasPanelID(rawValue: pane.rawValue))
        #expect(layout.isEmpty)
    }

    @Test func breakOutPanelCreatesFrontmostSingleTabPane() {
        var layout = CanvasLayout(panes: [singleTabPane(), singleTabPane(at: 400)])
        let destination = layout.paneIDs[0]
        let joining = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: joining.rawValue), frame: CanvasRect(x: 800, y: 0, width: 300, height: 200)))
        layout.addPanel(joining, toPane: destination)

        let newPaneID = CanvasPaneID(rawValue: UUID())
        let frame = CanvasRect(x: 1200, y: 0, width: 300, height: 200)
        let didBreak = layout.breakOutPanel(joining, intoPane: newPaneID, frame: frame)
        #expect(didBreak)

        #expect(layout.pane(containing: joining) == newPaneID)
        #expect(layout.paneIDs.last == newPaneID)
        #expect(layout.frame(of: newPaneID) == frame)
        // Breaking the now-single founding panel out of its pane is a no-op.
        let founding = CanvasPanelID(rawValue: destination.rawValue)
        let didBreakLone = layout.breakOutPanel(founding, intoPane: CanvasPaneID(rawValue: UUID()), frame: frame)
        #expect(!didBreakLone)
    }

    @Test func breakOutFoundingPanelOfMultiTabPane() {
        // A pane's id equals its founding panel's UUID. Tearing that founding
        // panel out into a *fresh* pane id must succeed and must not collide
        // with the source pane id.
        var layout = CanvasLayout(panes: [singleTabPane()])
        let destination = layout.paneIDs[0]
        let founding = CanvasPanelID(rawValue: destination.rawValue)
        let joined = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: joined.rawValue), frame: CanvasRect(x: 400, y: 0, width: 300, height: 200)))
        layout.addPanel(joined, toPane: destination, select: false)
        #expect(layout.panelIds(in: destination) == [founding, joined])

        let newPaneID = CanvasPaneID(rawValue: UUID())
        let frame = CanvasRect(x: 1200, y: 0, width: 300, height: 200)
        let didBreak = layout.breakOutPanel(founding, intoPane: newPaneID, frame: frame)
        #expect(didBreak)

        // The founding panel now lives alone in the new pane; the source pane
        // keeps the remaining tab and is no longer hosting the founding panel.
        #expect(layout.pane(containing: founding) == newPaneID)
        #expect(layout.panelIds(in: newPaneID) == [founding])
        #expect(layout.pane(containing: joined) == destination)
        #expect(layout.panelIds(in: destination) == [joined])
        #expect(layout.paneIDs.last == newPaneID)
        #expect(layout.frame(of: newPaneID) == frame)
    }

    @Test func selectPanelOnlyAffectsHostingPane() {
        var layout = CanvasLayout(panes: [singleTabPane()])
        let destination = layout.paneIDs[0]
        let a = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: a.rawValue), frame: CanvasRect(x: 400, y: 0, width: 300, height: 200)))
        layout.addPanel(a, toPane: destination, select: false)

        layout.selectPanel(a)
        #expect(layout.selectedPanelId(in: destination) == a)

        layout.selectPanel(panelID())
        #expect(layout.selectedPanelId(in: destination) == a)
    }

    @Test func codableRoundTripsTabs() throws {
        var layout = CanvasLayout(panes: [singleTabPane()])
        let destination = layout.paneIDs[0]
        let a = panelID()
        layout.add(CanvasPane(id: CanvasPaneID(rawValue: a.rawValue), frame: CanvasRect(x: 400, y: 0, width: 300, height: 200)))
        layout.addPanel(a, toPane: destination)

        let decoded = try JSONDecoder().decode(
            CanvasLayout.self,
            from: JSONEncoder().encode(layout)
        )
        #expect(decoded == layout)
    }
}

import CmuxMobileShell
import CmuxMobileShellModel
import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct PaneRackPresentationTests {
    @Test func visibilityMatrix() {
        let oneByOne = PaneRackPresentation(snapshot: snapshot(panes: [pane(id: "a", tabCount: 1)]))
        #expect(oneByOne.showsHeader == false)
        #expect(oneByOne.strips.isEmpty)

        let oneByMany = PaneRackPresentation(snapshot: snapshot(panes: [pane(id: "a", tabCount: 3)]))
        #expect(oneByMany.showsHeader)
        #expect(oneByMany.strips.isEmpty)

        let manyByMany = PaneRackPresentation(snapshot: snapshot(panes: [
            pane(id: "a", tabCount: 2),
            pane(id: "b", tabCount: 1),
            pane(id: "c", tabCount: 3),
        ]))
        #expect(manyByMany.showsHeader)
        #expect(manyByMany.strips.map(\.id) == ["b", "c"])
    }

    @Test func tailInterestIncludesStripsAndUnfoldedStageRows() {
        let presentation = PaneRackPresentation(snapshot: snapshot(panes: [
            pane(id: "a", tabCount: 2),
            pane(id: "b", tabCount: 1),
        ]))
        #expect(presentation.interestedSurfaceIDs(isUnfolded: false) == ["b-0"])
        #expect(presentation.interestedSurfaceIDs(isUnfolded: true) == ["a-0", "a-1", "b-0"])
    }

    @Test func glyphLayoutClampsNormalizedGeometry() {
        let layout = PaneMiniGlyphLayout(size: CGSize(width: 18, height: 13))
        let rect = layout.rect(for: .init(x: 0.5, y: -0.2, w: 0.8, h: 1.4))
        #expect(rect == CGRect(x: 9, y: 0, width: 9, height: 13))
    }

    private func snapshot(panes: [PaneRackPaneSnapshot]) -> PaneRackSnapshot {
        PaneRackSnapshot(
            workspaceID: .init(rawValue: "workspace"),
            panes: panes,
            stagedPaneID: "a",
            canCloseTabs: true
        )
    }

    private func pane(id: String, tabCount: Int) -> PaneRackPaneSnapshot {
        let tabs = (0..<tabCount).map { index in
            PaneRackTabSnapshot(
                id: .init(rawValue: "\(id)-\(index)"),
                title: "\(id)-\(index)",
                isReady: true,
                isMacFocused: index == 0,
                agentState: .idle
            )
        }
        return PaneRackPaneSnapshot(
            id: id,
            rect: .init(x: 0, y: 0, w: 1, h: 1),
            isMacFocused: id == "a",
            selectedTabID: tabs.first?.id,
            tabs: tabs
        )
    }
}

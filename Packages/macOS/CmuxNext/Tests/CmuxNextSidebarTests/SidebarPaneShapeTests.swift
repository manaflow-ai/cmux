import AppKit
@testable import CmuxNextSidebar
import Testing

/// The hover card's split miniature (ask-890db939a2): Leo's three-pane layout, a page on the left and a terminal
/// over a chat on the right, draws three tiles at the panes' real shares.
@MainActor
@Suite struct SidebarPaneShapeTests {
    private static let threePanes = SidebarPaneShape.split(
        axis: .horizontal, ratio: 0.6,
        .pane(.init(kind: .browser, focused: true)),
        .split(axis: .vertical, ratio: 0.5, .pane(.init(kind: .terminal)), .pane(.init(kind: .harness)))
    )

    @Test func threePanesDrawThreeTilesAtTheirShares() {
        let frames = Self.threePanes.frames(in: CGRect(x: 0, y: 0, width: 203, height: 103), gap: 3)
        #expect(frames.count == 3)
        #expect(frames.map(\.pane.kind) == [.browser, .terminal, .harness])
        #expect(frames[0].frame == CGRect(x: 0, y: 0, width: 120, height: 103))
        #expect(frames[1].frame == CGRect(x: 123, y: 0, width: 80, height: 50))
        #expect(frames[2].frame == CGRect(x: 123, y: 53, width: 80, height: 50))
        #expect(frames.filter(\.pane.focused).count == 1)
    }

    @Test func columnsShareTheRowByWidth() {
        let row = SidebarPaneShape.row([.init(width: 1, shape: .pane(.init(kind: .terminal))),
                                        .init(width: 3, shape: .pane(.init(kind: .browser)))])
        let frames = row.frames(in: CGRect(x: 0, y: 0, width: 102, height: 40), gap: 2)
        #expect(frames.map(\.frame.width) == [25, 75])
        #expect(frames[1].frame.minX == 27)
        #expect(row.paneCount == 2)
    }

    @Test func aSliverRatioStillDrawsBothSides() {
        let thin = SidebarPaneShape.split(axis: .horizontal, ratio: 0, .pane(.init(kind: nil)), .pane(.init(kind: nil)))
        let frames = thin.frames(in: CGRect(x: 0, y: 0, width: 100, height: 20), gap: 0)
        #expect(frames.allSatisfy { $0.frame.width >= 5 })
    }

    @Test func theCardShowsTheMiniatureOnlyForASplitWorkspace() {
        let card = WorkspaceHoverCardView()
        card.configurePaneShape(Self.threePanes)
        #expect(!card.paneShape.isHidden)
        #expect(card.paneShape.accessibilityLabel() == "Panes: 3")
        card.configurePaneShape(nil)
        #expect(card.paneShape.isHidden)
    }
}

import CoreGraphics
@testable import CmuxNextLayout
import Testing

/// A pane close shown in the key's turn (`LayoutModel.showPaneClose`) on a canvas screen: the
/// canvas draws its panes from its own frames, not the layout, so the closing pane leaves the
/// canvas in that turn too, not on the daemon's echo.
@MainActor struct PaneCloseCanvasTests {
    @Test func aPaneCloseOnACanvasLeavesTheCanvasInTheKeysTurn() {
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
            .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))))], activeScreenID: "s", focusedPane: "a")
        let seed: [PaneID: CGRect] = ["a": CGRect(x: 0, y: 0, width: 600, height: 700), "b": CGRect(x: 600, y: 0, width: 600, height: 700)]
        #expect(model.toggleCanvas(seed: seed, viewport: CGSize(width: 1200, height: 700)))
        #expect(model.canvases["s"]?.frames["b"] != nil)

        #expect(model.showPaneClose("b") != nil)

        #expect(model.canvases["s"]?.frames["b"] == nil, "the closing pane is still on the canvas until the daemon's echo")
    }
}

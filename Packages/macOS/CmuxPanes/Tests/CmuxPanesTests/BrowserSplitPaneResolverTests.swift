import CoreGraphics
import Testing
import Bonsplit
@testable import CmuxPanes

@MainActor
@Suite("BrowserSplitPaneResolver")
struct BrowserSplitPaneResolverTests {
    @Test(arguments: [SplitOrientation.horizontal, .vertical])
    func findsTheAdjacentPaneForTheRequestedOrientation(_ orientation: SplitOrientation) {
        let controller = BonsplitController()
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let sourcePane = controller.allPaneIds[0]
        _ = controller.createTab(title: "Terminal", kind: "terminal", inPane: sourcePane)
        let adjacentPane = controller.splitPane(
            sourcePane,
            orientation: orientation,
            withTab: Tab(title: "Browser", kind: "browser"),
            insertFirst: false
        )

        let resolved = BrowserSplitPaneResolver().preferredPane(
            from: sourcePane,
            in: controller,
            orientation: orientation
        )

        #expect(adjacentPane != nil)
        #expect(resolved == adjacentPane)
    }
}

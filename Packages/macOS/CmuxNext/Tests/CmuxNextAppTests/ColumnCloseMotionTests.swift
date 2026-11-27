import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Closing a column revealed beside a chat brings the chat back in the turn of the close, while its
/// workspace stays visible: the close is one commit, with no pane and no camera on a spring.
@MainActor
@Suite(.closesItsWindows)
struct ColumnCloseMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screen {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow
        let columns: [LayoutColumn]

        init(reduceMotion: Bool) {
            let columns = [LayoutColumn(id: "c1", width: 1, root: .leaf("chat")),
                           LayoutColumn(id: "c2", width: 1, root: .leaf("files"))]
            self.columns = columns
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))],
                                activeScreenID: "s", focusedPane: "chat")
            model.followsDesignMetrics = false
            model.baseStyle.columnGap = 0
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = reduceMotion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
        }

        func settle() {
            for _ in 0..<240 { if !root.advanceFrame(1.0 / 120) { break } }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func closingTheRevealedColumnBringsTheChatBack(collapseToLeaf: Bool, reduceMotion: Bool) throws {
        let fixture = Screen(reduceMotion: reduceMotion)
        defer { fixture.window.closeAfterTest() }
        let screen = try #require(fixture.root.screenViews["s"])
        fixture.model.revealColumn(containing: "files")
        fixture.root.syncWithModel()
        fixture.settle()
        #expect(fixture.model.focusedPane == "chat")
        #expect(screen.scroll.value > 0)
        #expect(!screen.hasMotion)
        #expect(!screen.visiblePanes().contains("chat"))
        #expect(screen.visiblePanes().contains("files"))

        let layout: ScreenLayout = collapseToLeaf ? .splits(.leaf("chat")) : .columns([fixture.columns[0]])
        fixture.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: layout)])
        fixture.root.syncWithModel()
        #expect(!screen.isHidden)
        #expect(screen.scroll.value >= 0 && screen.scroll.value <= screen.geometry.maxOffset,
                "the camera stayed beyond the removed column")
        #expect(screen.scroll.target >= 0 && screen.scroll.target <= screen.geometry.maxOffset)
        // The close is one commit: its own turn puts the camera at its place in the strip that stays
        // and leaves no pane on a spring, so the chat is on screen at once, with motion on or off.
        #expect(!screen.hasMotion, "the close left a pane or the camera on a spring")
        #expect(screen.visiblePanes().contains("chat"), "the chat is not on screen in the turn of the close")
        // A manual clock would mask a frame request: a scroll sync after the close asks for none.
        let needsFrames = screen.syncScroll(focused: "chat", source: .programmatic,
                                            mode: fixture.model.centerFocusedColumn, animated: !reduceMotion)
        #expect(!needsFrames, "a scroll sync after the close asked for frames")
        fixture.settle()

        let shown = try #require(screen.displayedFrame(of: "chat"))
        #expect(screen.bounds.insetBy(dx: -0.5, dy: -0.5).contains(shown), "the chat rested off screen: \(shown)")
        #expect(screen.scroll.value == 0 && screen.scroll.target == 0)
        #expect(!screen.hasMotion)
        #expect(screen.visiblePanes().contains("chat"))
    }
}

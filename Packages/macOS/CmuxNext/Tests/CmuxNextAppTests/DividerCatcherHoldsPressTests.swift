import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// Leo (2026-11-07, Trace-ID ask-2512d634b0): the cmux NEXT divider drag has "horrendous lag ... not able to move very
/// far, if at all". Over a Chromium page a divider press lands on a click-catching panel (`DividerMouseCatchers`), and the
/// drag's moves and its release come to that panel's window wherever the pointer goes. The press starts a resize
/// motion, which detaches an unfocused page from the window (#36541). With no page window left over the content,
/// `WindowOverlayLayer.evaluate()` moved the overlay back into the window and synced the catchers, which parked the
/// panel that held the press (no size, no mouse) and took it out of the window: its moves had no parent to go to, so
/// the divider stopped where the press found it.
///
/// The rule: a panel that holds a press stays shown, takes the mouse and keeps its parent until the release; the
/// release applies the catchers' last update.
@MainActor @Suite(.serialized, .closesItsWindows) struct DividerCatcherHoldsPressTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    /// A shown shell window with two side-by-side panes and one page child window over its content, as the fork adds one.
    final class Layout {
        let window: ShellWindow
        let model: LayoutModel
        let root: LayoutRootView
        let page: NSWindow
        private let provider = Panes()

        init() {
            _ = NSApplication.shared
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(
                .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))
            ))], activeScreenID: "s", focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = true
            window = ShellWindow(contentRect: NSRect(x: 200, y: 200, width: 1200, height: 800), styleMask: [.titled, .resizable],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            // The test is the clock: the display link never ticks.
            root.driver.isManual = true
            page = NSWindow(contentRect: window.frame.insetBy(dx: 40, dy: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            page.isReleasedWhenClosed = false
            window.addChildWindow(page, ordered: .above)
            window.overlayLayer.evaluate()
            settle()
        }

        /// As `WindowController.teardown` closes a shell window: the overlay layer's teardown (its catcher panels) first.
        func close() {
            window.overlayLayer.teardown()
            if page.parent === window { window.removeChildWindow(page) }
            page.close()
            window.close()
        }

        var catchers: DividerMouseCatchers { window.overlayLayer.catchers }

        func settle() {
            var frames = 0
            while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
            root.layoutSubtreeIfNeeded()
        }

        /// The catcher panels that show and take the mouse.
        var shownPanels: [DividerMousePanel] {
            (window.childWindows ?? []).compactMap { $0 as? DividerMousePanel }
                .filter { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.size != .zero }
        }

        /// The x (window coordinates) of the left pane's right edge: the divider as the screen shows it.
        func dividerX() throws -> CGFloat {
            let screen = try #require(root.screenViews["s"])
            let frame = try #require(screen.displayedFrame(of: "p1"), "p1 shows no frame")
            return screen.convert(frame, to: nil).maxX
        }

        /// A window server mouse event at `point` (screen coordinates), as the panel under it gets one.
        func event(_ type: CGEventType, _ point: CGPoint) throws -> NSEvent {
            let height = try #require(NSScreen.screens.first?.frame.height, "no screen")
            let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: height - point.y),
                                          mouseButton: .left))
            return try #require(NSEvent(cgEvent: cg))
        }
    }

    @Test func aPanelThatHoldsAPressKeepsTheDragWhenItsPageLeaves() throws {
        let layout = Layout()
        defer { layout.close() }
        // The test presses no hardware button: the press holds the button down until its release.
        var buttonDown = false
        layout.catchers.isLeftButtonDown = { buttonDown }
        let panel = try #require(layout.shownPanels.first, "the divider over the page has a catcher panel: \(layout.catchers.framesInWindow)")
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let before = try layout.dividerX()

        buttonDown = true
        panel.catcher.mouseDown(with: try layout.event(.leftMouseDown, start))
        try #require(layout.root.isDividerDragging, "the press on the catcher panel started the divider drag")

        // The resize motion detaches the unfocused page: it leaves the window, and the window checks its page windows.
        layout.window.removeChildWindow(layout.page)
        layout.page.orderOut(nil)
        layout.window.overlayLayer.evaluate()

        #expect(panel.parent === layout.window, "the panel that holds the press left the window mid-drag")
        #expect(panel.isVisible && !panel.ignoresMouseEvents && panel.frame.size != .zero,
                "the panel that holds the press was parked mid-drag: visible \(panel.isVisible), ignores \(panel.ignoresMouseEvents), \(panel.frame)")

        var point = start
        for _ in 0..<12 {
            point.x += 10
            panel.catcher.mouseDragged(with: try layout.event(.leftMouseDragged, point))
            _ = layout.root.advanceFrame(1.0 / 120)
        }
        layout.root.layoutSubtreeIfNeeded()
        let moved = try layout.dividerX() - before
        #expect(abs(moved - 120) <= 2, "the divider moved \(moved) pt of the pointer's 120 pt")

        buttonDown = false
        panel.catcher.mouseUp(with: try layout.event(.leftMouseUp, point))
        layout.settle()
        // No page is over the content any more: the release puts the held panel away.
        #expect(layout.shownPanels.isEmpty, "a catcher panel still shows after the release with no page: \(layout.catchers.framesInWindow)")
        #expect(!layout.root.isDividerDragging, "the release ended the drag")
    }

    /// The control: a press with the page still over the content changes nothing about the panels at the release.
    @Test func aPressWithThePageInPlaceKeepsItsPanelAfterTheRelease() throws {
        let layout = Layout()
        defer { layout.close() }
        var buttonDown = false
        layout.catchers.isLeftButtonDown = { buttonDown }
        let panel = try #require(layout.shownPanels.first)
        let start = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        buttonDown = true
        panel.catcher.mouseDown(with: try layout.event(.leftMouseDown, start))
        layout.window.overlayLayer.evaluate()
        buttonDown = false
        panel.catcher.mouseUp(with: try layout.event(.leftMouseUp, start))
        layout.settle()
        #expect(layout.shownPanels.count == 1, "the divider over the page keeps its panel: \(layout.catchers.framesInWindow)")
    }
}

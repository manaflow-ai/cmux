import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A layout frame that moves many panes re-checks the window's traffic-light avoiders once, not once per moved pane
/// (RESIZE VIDEOS F1, lead item 3; dod-audit 2.2 `noteWindowFrame`). Every pane's content hears that its frame in the
/// window changed (`paneFrameInWindowDidChange`), and the app's pane content asks the window to re-check every
/// avoider there (`WindowControlsAvoiders.refresh`): with 6 panes moving, each frame re-checked every avoider 6
/// times, an ancestor walk and a window convert each. Now the layout's frame and its model sync batch those asks:
/// each avoider re-checks once per frame. The test is the clock (120 Hz).
@MainActor
@Suite(.closesItsWindows)
struct AvoiderRefreshPerFrameTests {
    /// Pane content that asks for an avoider refresh when its frame in the window changes, as the app's does.
    final class Content: NSView, PaneContentChrome {
        var paneHeaderHeight: CGFloat { 0 }
        var onPaneHeaderHeightChange: (() -> Void)?
        func setPaneContentCornerRadius(_ radius: CGFloat) {}
        func paneFrameInWindowDidChange() { WindowControlsAvoiders.refresh(in: window) }
    }

    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { Content() }
    }

    final class Window: NSWindow, WindowControlsAvoidanceHosting {
        let windowControlsAvoiders = WindowControlsAvoiders()
    }

    final class Avoider: NSView, WindowControlsAvoiding {
        var checks = 0
        func updateWindowControlsAvoidance() { checks += 1 }
    }

    @Test func aFrameThatMovesSixPanesRechecksEachAvoiderOnce() throws {
        let columns = (1...6).map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.3, root: .leaf(PaneID("p\($0)"))) }
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p6")
        let provider = Panes()
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = Window(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = container
        root.frame = container.bounds
        container.addSubview(root)
        let avoider = Avoider(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(avoider)
        window.windowControlsAvoiders.add(avoider)
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for _ in 0..<600 where root.advanceFrame(1.0 / 120) {}

        // The camera goes from the last column to the first: every strip pane moves on every frame.
        model.focus("p1", notify: false)
        root.syncWithModel()
        var frames = 0, worst = 0, moved = 0
        avoider.checks = 0
        while frames < 600 {
            let before = avoider.checks
            let moving = root.advanceFrame(1.0 / 120)
            frames += 1
            worst = max(worst, avoider.checks - before)
            moved = max(moved, root.panesMovedInLastOverlaySync.count)
            if !moving { break }
        }
        #expect(moved >= 4, "the camera move moves several panes in one frame (\(moved))")
        #expect(worst <= 1, "one frame re-checked the avoider \(worst) times (once per moved pane)")
        #expect(avoider.checks >= 1, "the moves re-checked the avoider")
    }
}

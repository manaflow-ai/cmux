import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS K3 (cmux-ad 2026-11-02 P0; lead 21:1xZ: "hold pane content during a key resize spring, one reflow at
/// the landing"). Film rk-browser-agent (feat 507438d): with a browser page and an agent chat right of the divider,
/// every Ctrl-Shift-H/L lost 5-8 refreshes. Profile rk-xtpa-browser-agent: no single item over 8.3 ms; each dropped
/// frame (9-26 ms) was the pane contents laid out at the spring's live size: the CA commit (tracking areas, drag
/// regions, tab label glyphs, constraints), the browser chrome, the CEF content view and its child window, the chat's
/// SwiftUI graph. During a key resize spring each pane's content keeps its size (clipped) and lays out once.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeContentHoldTests {
    final class Recorder: NSView {
        var sizes: [CGSize] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize != frame.size { sizes.append(newSize) }
            super.setFrameSize(newSize)
        }
    }

    final class Panes: LayoutPaneContentProvider {
        var views: [PaneID: Recorder] = [:]
        func makeContentView(for pane: PaneID) -> NSView {
            let view = Recorder()
            views[pane] = view
            return view
        }
    }

    @Test(arguments: [LayoutDirection.left, .right])
    func eachPaneContentResizesAtMostOncePerKeyPress(direction: LayoutDirection) throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        for view in provider.views.values { view.sizes.removeAll() }
        let host1 = try #require(root.context.hosts["p1"]), host2 = try #require(root.context.hosts["p2"])
        let before = (host1.frame, host2.frame)
        #expect(PaneResize.press("p2", direction, model: model, view: root))
        root.syncWithModel()
        var frames = 0
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
        }
        root.layoutSubtreeIfNeeded()
        for work in afterCommit { work() }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the press did not spring (\(frames) frames)")
        #expect(host1.frame != before.0 && host2.frame != before.1, "the press moved nothing")
        for (pane, view) in provider.views {
            #expect(view.sizes.count <= 1, "\(pane)'s content resized \(view.sizes.count) times in one key press: \(view.sizes.prefix(4))")
            #expect(view.frame.size == view.superview?.bounds.size, "\(pane) did not land at its final size")
        }
    }
}

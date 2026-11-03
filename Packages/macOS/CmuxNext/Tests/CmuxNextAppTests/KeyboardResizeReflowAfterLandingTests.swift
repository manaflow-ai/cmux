import AppKit
import CmuxNextBridge
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE KEYS K3, second part. After films rk-k3ff-b2..b5 (content hold 3e14e9205bb): H/L drops went from 4-8 to 0-2
/// per press, and the profile (rk-k3ff-x1, app clock) names the rest: the one content layout ran inside a motion
/// frame: in the key's own turn for the growing panes (page, chat and CEF child window at their final size, 10-24 ms)
/// and in the landing frame for the shrinking ones (11-17 ms). No content may lay out in the key turn or in any frame
/// of the spring: each pane's content keeps its start size through the motion and lays out once, after the landing
/// frame's commit (`LayoutViewContext.afterCommit`), when nothing moves.
@MainActor
@Suite(.closesItsWindows)
struct KeyboardResizeReflowAfterLandingTests {
    typealias Panes = KeyboardResizeContentHoldTests.Panes

    @Test(arguments: [LayoutDirection.left, .right])
    func contentLaysOutOnlyAfterTheLandingFrame(direction: LayoutDirection) throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s", focusedPane: "p2")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        var afterCommit: [@MainActor () -> Void] = []
        root.context.afterCommit = { afterCommit.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.closeAfterTest() }
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        for view in provider.views.values { view.sizes.removeAll() }
        #expect(PaneResize.press("p2", direction, model: model, view: root))
        root.syncWithModel()
        var frames = 0
        while frames < 240, root.advanceFrame(1.0 / 120) {
            root.layoutSubtreeIfNeeded()
            frames += 1
        }
        root.layoutSubtreeIfNeeded()
        #expect(frames > 3, "the press did not spring")
        for (pane, view) in provider.views {
            #expect(view.sizes.isEmpty, "\(pane)'s content laid out in the key turn or a motion frame: \(view.sizes)")
        }
        // After the landing frame's commit: one layout each, at the size the pane rests at.
        for work in afterCommit { work() }
        root.layoutSubtreeIfNeeded()
        for (pane, view) in provider.views {
            let host = try #require(root.context.hosts[pane])
            #expect(view.sizes.count == 1, "\(pane)'s content laid out \(view.sizes.count) times after the landing")
            #expect(view.frame.size == view.superview?.bounds.size, "\(pane)'s content is not at its rest size: \(view.frame.size) in \(String(describing: view.superview?.bounds.size)) (host \(host.frame.size))")
        }
    }
}

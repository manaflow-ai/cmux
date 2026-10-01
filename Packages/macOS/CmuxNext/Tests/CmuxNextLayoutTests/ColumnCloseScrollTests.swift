import AppKit
import Testing
@testable import CmuxNextLayout

/// The live strip: closing the rightmost column springs the view back (no
/// jump, no empty space at rest), and closing a column left of the focused
/// one leaves the focused column where it is on screen.
@MainActor
struct ColumnCloseScrollTests {
    private func columns(_ ids: [String], width: Double = 0.5) -> [LayoutScreen] {
        [LayoutScreen(id: "s", name: "", layout: .columns(ids.map { LayoutColumn(id: ColumnID("c\($0)"), width: width, root: .leaf(PaneID($0))) }))]
    }

    private func makeRoot(_ screens: [LayoutScreen], focused: PaneID, followsDesignMetrics: Bool = true) -> (LayoutRootView, NSWindow, CloseScrollProvider) {
        let model = LayoutModel(screens: screens, activeScreenID: "s", focusedPane: focused)
        model.followsDesignMetrics = followsDesignMetrics
        let provider = CloseScrollProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window, provider)
    }

    /// Waits (up to 5 s of wall time) for `condition`; springs run on the
    /// window's display link, so this needs real time, not just yields.
    private func settle(_ view: LayoutRootView, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func closingTheRightmostColumnSpringsBack() async {
        let (view, window, provider) = makeRoot(columns(["a", "b", "c"]), focused: "a")
        defer { window.close() }
        guard view.driver.isAttached, !view.context.reduceMotion else { return }
        let screen = view.screenViews["s"]!
        view.model.focus("c")
        await settle(view) { !view.driver.isRunning && screen.scroll.value > 0 }
        let before = screen.scroll.value
        #expect(before == screen.geometry.maxOffset)

        view.model.apply(screens: columns(["a", "b"]))
        view.model.focus("b", notify: false)
        await settle(view) { screen.geometry.columnOrder.count == 2 }
        // Right after the close the view has not jumped to the new end: it is
        // still past it (at most a few frames into the spring), springing back.
        #expect(screen.scroll.target == screen.geometry.maxOffset)
        #expect(screen.scroll.value > screen.geometry.maxOffset + 1)
        #expect(screen.scroll.value <= before)
        #expect(view.driver.isRunning)
        await settle(view) { !view.driver.isRunning }
        #expect(screen.scroll.value == screen.geometry.maxOffset)
        #expect(abs((view.frame(of: "b")?.maxX ?? 0) + screen.context.style.stripGap - 1000) < 0.5)
        withExtendedLifetime(provider) {}
    }

    @Test func closingAColumnLeftOfTheFocusKeepsTheFocusedColumnStill() async {
        let (view, window, provider) = makeRoot(columns(["a", "b", "c", "d"]), focused: "a", followsDesignMetrics: false)
        defer { window.close() }
        // This test compares frames across an update. Pin the model to its
        // base style so another live DesignSettings test cannot change the
        // strip gap between the two observations.
        let screen = view.screenViews["s"]!
        view.model.focus("c")
        await settle(view) {
            guard let frame = view.frame(of: "c") else { return false }
            return !view.driver.isRunning && frame.minX > 0 && frame.maxX <= view.bounds.maxX
        }
        let before = view.frame(of: "c")
        #expect(before != nil)

        view.model.apply(screens: columns(["b", "c", "d"]))
        await settle(view) {
            guard let frame = view.frame(of: "c") else { return false }
            return screen.geometry.columnOrder.count == 3 && !view.driver.isRunning
                && frame.minX > 0 && frame.maxX <= view.bounds.maxX
        }
        #expect(view.frame(of: "c") == before)
        withExtendedLifetime(provider) {}
    }
}

private final class CloseScrollProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

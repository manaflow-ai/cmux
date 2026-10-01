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

    private func makeRoot(_ screens: [LayoutScreen], focused: PaneID) -> (LayoutRootView, NSWindow, CloseScrollProvider) {
        let model = LayoutModel(screens: screens, activeScreenID: "s", focusedPane: focused)
        let provider = CloseScrollProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (view, window, provider)
    }

    /// Waits (up to 5 s of wall time) for `condition`; model changes reach
    /// the view through an observation task, so this needs real yields.
    private func settle(_ view: LayoutRootView, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Steps the springs at 60 Hz until they rest. They normally run on the
    /// window's display link, which need not fire for an offscreen test
    /// window (a headless CI Mac), so the test drives the frames itself. A
    /// display link that does fire goes through the same `onFrame`.
    private func runToRest(_ view: LayoutRootView) {
        for _ in 0..<600 {
            guard view.driver.onFrame?(1.0 / 60) == true else { return }
        }
        Issue.record("springs still moving after 10 s of frames")
    }

    @Test func closingTheRightmostColumnSpringsBack() async {
        let (view, window, provider) = makeRoot(columns(["a", "b", "c"]), focused: "a")
        defer { window.close() }
        guard view.driver.isAttached, !view.context.reduceMotion else { return }
        let screen = view.screenViews["s"]!
        view.model.focus("c")
        await settle(view) { screen.scroll.target > 0 }
        runToRest(view)
        let before = screen.scroll.value
        #expect(before == screen.geometry.maxOffset)

        // Record every frame from here on, whoever drives it.
        var frames: [(from: CGFloat, to: CGFloat)] = []
        let step = view.driver.onFrame
        view.driver.onFrame = { dt in
            let from = screen.scroll.value
            let keepGoing = step?(dt) ?? false
            frames.append((from, screen.scroll.value))
            return keepGoing
        }
        view.model.apply(screens: columns(["a", "b"]))
        view.model.focus("b", notify: false)
        await settle(view) { screen.geometry.columnOrder.count == 2 }
        #expect(screen.scroll.target == screen.geometry.maxOffset)
        runToRest(view)
        // The close did not jump to the new end: the first frame starts where
        // the view was, past the new end, and springs back from there.
        #expect(frames.first?.from == before)
        #expect(before > screen.geometry.maxOffset + 1)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.to <= $0.to + 0.5 })
        #expect(frames.last?.to == screen.geometry.maxOffset)
        #expect(screen.scroll.value == screen.geometry.maxOffset)
        #expect(abs((view.frame(of: "b")?.maxX ?? 0) + screen.context.style.stripGap - 1000) < 0.5)
        withExtendedLifetime(provider) {}
    }

    @Test func closingAColumnLeftOfTheFocusKeepsTheFocusedColumnStill() async {
        let (view, window, provider) = makeRoot(columns(["a", "b", "c", "d"]), focused: "a")
        defer { window.close() }
        let screen = view.screenViews["s"]!
        view.model.focus("c")
        await settle(view) { screen.scroll.target > 0 }
        runToRest(view)
        let before = view.frame(of: "c")
        #expect(before != nil)
        #expect(screen.scroll.value > 0)

        view.model.apply(screens: columns(["b", "c", "d"]))
        await settle(view) { screen.geometry.columnOrder.count == 3 }
        runToRest(view)
        #expect(view.frame(of: "c") == before)
        withExtendedLifetime(provider) {}
    }
}

private final class CloseScrollProvider: LayoutPaneContentProvider {
    func makeContentView(for pane: PaneID) -> NSView { NSView() }
}

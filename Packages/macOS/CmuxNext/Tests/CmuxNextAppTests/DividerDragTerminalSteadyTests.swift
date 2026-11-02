import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import Testing

/// A person's divider drag keeps each terminal's text where it is until the drag lands (RESIZE VIDEOS A3, film
/// col-drag-fast frames 124-131: the left column's text wrapped again on every drag frame). The PTY already resizes
/// once per drag (#31613), but the surface took the pane's size on every drag event and drew its grid reflowed to it
/// (Ghostty's reflow preview), so the wrap point moved in every frame. Through the drag the surface now keeps its
/// size (clipped where the pane is narrower, the terminal background beside it where wider), as a Chromium page
/// keeps its size through a drag; when the drag lands it takes the pane's size and reflows once.
/// Real terminal sessions behind the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test is the clock.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragTerminalSteadyTests {
    typealias Harness = SplitTerminalResizeCountTests

    @Test func aDividerDragKeepsEachTerminalsSurfaceSizeUntilItLands() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        let left = try #require(screen.terminals["p1"]?.session.surfaceView)
        let before = left.bounds.size

        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        var sizes: Set<CGFloat> = []
        for step in 1...30 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await screen.step()
            sizes.insert(left.bounds.width)
        }
        let hostWidth = try #require(left.superview?.bounds.width)
        #expect(hostWidth < before.width - 100, "the drag narrowed p1's pane (\(before.width) -> \(hostWidth))")
        #expect(sizes == [before.width], "p1's surface took \(sizes.count) widths during the drag: \(sizes.sorted())")

        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 240, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the release never landed")
        await screen.drain()
        let after = try #require(left.superview?.bounds.width)
        #expect(abs(left.bounds.width - after) < 40, "after the drag landed p1's surface fits its pane again (\(left.bounds.width) vs \(after))")
        #expect(left.bounds.width < before.width - 100, "the surface reflowed to the narrower pane once the drag landed")
    }
}

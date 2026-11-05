import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// cmux-ad m14/m18 (the drag hold `terminalDrag.holdSurface` is off by default since cmux-ad m19, 2026-11-05): in each
/// frame of a divider drag each terminal's surface takes its pane's size, so Ghostty's reflow preview re-wraps its text
/// at that size; its PTY still resizes once, when the drag lands (`DividerDragTerminalResizeCountTests`). Before m19 the
/// hold kept each surface at its drag-start size until the drag landed (RESIZE VIDEOS A3).
/// Real terminal sessions behind the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test is the clock.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragTerminalSteadyTests {
    typealias Harness = SplitTerminalResizeCountTests

    @Test func aDividerDragGivesEachTerminalsSurfaceItsPanesSizeInEveryFrame() async throws {
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
        #expect(sizes.count >= 25, "p1's surface took \(sizes.count) widths in 30 drag steps: the drag holds it (\(sizes.sorted()))")
        #expect(abs(left.bounds.width - hostWidth) < 40, "p1's surface follows its pane in the drag (\(left.bounds.width) in \(hostWidth))")

        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 240, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        #expect(!moving, "the release never landed")
        await screen.drain()
        let after = try #require(left.superview?.bounds.width)
        #expect(abs(left.bounds.width - after) < 40, "after the drag landed p1's surface fits its pane again (\(left.bounds.width) vs \(after))")
        #expect(left.bounds.width < before.width - 100, "the surface keeps the narrower pane's size after the drag landed")
    }

    /// A surface swapped in mid-drag (a replay puts a fresh surface in the host, `TerminalSession.swapSurface`) takes its
    /// pane's size, not the drag start's.
    @Test func aSurfaceSwappedInMidDragTakesItsPanesSize() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        let session = try #require(screen.terminals["p1"]?.session)
        let host = session.view
        let before = session.surfaceView.bounds.size

        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        for step in 1...20 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await screen.step()
        }
        #expect(session.surfaceView.bounds.width < before.width - 100,
                "p1's surface follows its narrower pane in the drag (\(session.surfaceView.bounds.width) pt, \(before.width) at the start)")

        let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        defer { continuation.finish() }
        let fresh = TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL, input: TerminalInputSink(continuation: continuation), session: nil)
        host.install(fresh)
        host.layoutSubtreeIfNeeded()
        #expect(fresh.frame.width < before.width - 100,
                "the fresh surface kept the old surface's drag hold (\(fresh.frame.width) pt in a \(host.bounds.width) pt host)")
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 160, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await screen.step() }
        host.layoutSubtreeIfNeeded()
        #expect(abs(fresh.frame.width - host.bounds.width) < 40, "after the landing the fresh surface fits its pane (\(fresh.frame.width) vs \(host.bounds.width))")
    }
}

import AppKit
import CmuxNextBridge
import CmuxNextTestSupport
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// cmux-ad m14 (Lawrence's P0, "resizing splits/columns, still not animating the terminals"): in every frame of a divider
/// drag, and of the spring its release starts, each terminal takes its pane's size, so its text re-wraps at that size
/// (the reflow preview) and never stays frozen at the drag's start; its PTY still resizes once, when the release lands
/// (`DividerDragTerminalResizeCountTests`). Before: the drag hold (`terminalDrag.holdSurface`, RESIZE VIDEOS A3) kept
/// each surface at its drag-start size for the whole drag, clipped where the pane was narrower and beside the terminal
/// background where it was wider, and the release's spring held its final size; pixel-perfect's trace (STATUS 13764)
/// counted 157-159 held ticks per col-drag-2 film, the surface up to 150 pt off its pane.
/// Real terminal sessions behind the app's ResizeCoordinator (`SplitTerminalResizeCountTests`); the test is the clock and
/// runs each frame's layout pass. cmux-ad m26 (T-KEYS) deleted `motion.frameOwner.terminals` and its off path, so no
/// switch is pinned; `TerminalDividerDragFrameTests` checks the drag on screen.
@MainActor
@Suite(.closesItsWindows)
struct DividerDragTerminalSteadyTests {
    typealias Harness = SplitTerminalResizeCountTests

    /// Where `pane`'s surface stands against the area its host shows it in, one line per miss.
    static func miss(_ screen: Harness.Screen, _ pane: PaneID, _ label: String) throws -> String? {
        let session = try #require(screen.terminals[pane]?.session)
        let host = session.view, surface = session.surfaceView.frame
        let area = host.surfaceSize(forHostSize: host.bounds.size)
        guard abs(surface.width - area.width) > 0.5 || abs(surface.height - area.height) > 0.5 || abs(surface.minX) > 0.5 else { return nil }
        return "\(label): \(pane)'s surface \(surface.size) at x \(surface.minX) in a \(area) area"
    }

    /// One display frame, then the frame's layout pass. Returns whether anything still moves.
    @discardableResult
    static func frame(_ screen: Harness.Screen) async -> Bool {
        let moving = await screen.step()
        screen.root.layoutSubtreeIfNeeded() // sync-layout: the frame's own layout pass, as the frame tick runs it
        return moving
    }

    @Test func aDividerDragGivesEachTerminalItsPanesSizeInEveryFrame() async throws {
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
        var widths: Set<CGFloat> = [], misses: [String] = []
        for step in 1...30 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await Self.frame(screen)
            widths.insert(left.bounds.width)
            for pane: PaneID in ["p1", "p2"] { if let miss = try Self.miss(screen, pane, "drag step \(step)") { misses.append(miss) } }
        }
        let hostWidth = try #require(left.superview?.bounds.width)
        #expect(hostWidth < before.width - 100, "the drag narrowed p1's pane (\(before.width) -> \(hostWidth))")
        #expect(widths.count >= 25, "p1's surface took \(widths.count) widths in 30 drag steps: the drag holds it (\(widths.sorted()))")

        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 240, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, frames = 0
        while moving, frames < 240 {
            moving = await Self.frame(screen)
            frames += 1
            for pane: PaneID in ["p1", "p2"] { if let miss = try Self.miss(screen, pane, "release frame \(frames)") { misses.append(miss) } }
        }
        #expect(!moving, "the release never landed")
        await screen.drain()
        for pane: PaneID in ["p1", "p2"] { if let miss = try Self.miss(screen, pane, "at rest") { misses.append(miss) } }
        #expect(misses.isEmpty, "\(misses.count) frames showed a terminal at another size than its pane's (first 6):\n\(misses.prefix(6).joined(separator: "\n"))")
        #expect(left.bounds.width < before.width - 100, "the surface took the narrower pane's size")
    }

    /// A drag that catches a split's spring (the press lands on the divider while the panes still move): the spring's
    /// hold at its final size ends at the drag's first frame, and the surface follows the drag from there.
    @Test func aDragThatCatchesASplitsSpringFollowsThePaneFromItsFirstFrame() async throws {
        _ = NSApplication.shared
        let screen = Harness.Screen(Harness.pair)
        defer { screen.close() }
        try screen.attachTerminal("p1")
        try screen.attachTerminal("p2")
        await screen.drain()
        // The split's spring starts: each terminal holds the size it will rest at (a split's rule, unchanged).
        let changes = screen.model.splitSizingChanges(splitting: "p2", axis: .horizontal)
        _ = screen.model.showSplitSizing(changes)
        screen.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(Harness.pairSplit))])
        screen.root.syncWithModel()
        for _ in 1...4 { await Self.frame(screen) }
        let p2 = try #require(screen.terminals["p2"]?.session)
        try #require(p2.surfaceView.frame.width < p2.view.bounds.width - 20,
                     "the split's spring holds p2 at its final size (\(p2.surfaceView.frame.width) pt in a \(p2.view.bounds.width) pt host)")
        let view = try #require(screen.root.screenViews["s"])
        let handle = try #require(view.dividerViews[.split("r")])
        let start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        view.handleDrag(kind: .split("r"), event: .began(start, []))
        var misses: [String] = []
        for step in 1...12 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await Self.frame(screen)
            for pane: PaneID in ["p1", "p2"] { if let miss = try Self.miss(screen, pane, "drag step \(step)") { misses.append(miss) } }
        }
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 96, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true
        for _ in 1...240 where moving { moving = await Self.frame(screen) }
        #expect(misses.isEmpty, "\(misses.count) drag frames showed a terminal at another size than its pane's: \(misses.prefix(4))")
    }

    /// A surface swapped in mid-drag (a replay puts a fresh surface in the host, `TerminalSession.swapSurface`) follows the
    /// drag too: it takes its pane's size in every frame left, its release spring holds no final size, and it stops
    /// following when the release lands. Codex review of b72c7e2d3fa (blocker): the drag was told only to the surfaces
    /// shown at its start, so a fresh one got the release spring's final-size hold (and a grid report on every frame).
    @Test func aSurfaceSwappedInMidDragFollowsTheDrag() async throws {
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
        for step in 1...10 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await Self.frame(screen)
        }
        let (_, continuation) = AsyncStream<TerminalOutgoing>.makeStream()
        defer { continuation.finish() }
        let fresh = TerminalSurfaceView(io: GHOSTTY_SURFACE_IO_MANUAL, input: TerminalInputSink(continuation: continuation), session: nil)
        host.install(fresh)
        host.layoutSubtreeIfNeeded()
        #expect(fresh.isFollowingResizeGesture, "the fresh surface does not follow the drag under way")
        var misses: [String] = []
        func check(_ label: String) {
            let area = host.surfaceSize(forHostSize: host.bounds.size)
            if abs(fresh.frame.width - area.width) > 0.5 || abs(fresh.frame.height - area.height) > 0.5 {
                misses.append("\(label): \(fresh.frame.size) in a \(area) area")
            }
        }
        check("at the swap")
        for step in 11...20 {
            view.handleDrag(kind: .split("r"), event: .moved(CGPoint(x: start.x - CGFloat(step) * 8, y: start.y), []))
            screen.root.syncWithModel()
            await Self.frame(screen)
            check("drag step \(step)")
        }
        #expect(fresh.bounds.width < before.width - 100, "the fresh surface did not narrow with its pane (\(fresh.bounds.width) pt)")
        view.handleDrag(kind: .split("r"), event: .ended(CGPoint(x: start.x - 160, y: start.y), []))
        screen.root.syncWithModel()
        var moving = true, frames = 0
        while moving, frames < 240 {
            moving = await Self.frame(screen)
            frames += 1
            check("release frame \(frames)")
        }
        #expect(!moving, "the release never landed")
        #expect(misses.isEmpty, "\(misses.count) frames showed the fresh surface at another size than its pane's: \(misses.prefix(6))")
        #expect(!fresh.isFollowingResizeGesture, "the fresh surface still follows a drag that landed")
    }
}

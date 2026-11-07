import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S1B 1b: a tab open, close or move that starts while the window's frames tick (a key resize's
/// spring) runs on the frame clock, as the pane motion it shows with does. Panes step from the time the last frame
/// showed (`FrameScheduler`'s target, S2); a strip move began at the event turn's `CACurrentMediaTime()` on the
/// render server's own clock, so in the same frame the strip and the panes showed different times of their motion,
/// and a closing tab went when a move begun "now" ended, not when the motion it showed ended.
///
/// The window's own scheduler ticks (a frame client is active and one frame is given by hand, as a display link does);
/// then, in the next event turn, a tab closes.
/// (a) The closing cell's width path, at each later frame time t, is the tween at t minus the time the last frame
///     showed (the motion origin), never at t minus the event turn's time.
/// (b) An origin a little ahead of now (the last frame's target is still to show): no frame shows the end value before
///     the move begins (backward fill), and the moves begin at the origin.
/// (c) The closing tab goes when the motion it shows ends: the origin plus the close's duration, also for an origin
///     50 ms back (a late event turn).
/// (d) Reduce Motion: the close lands at once and the tab goes in the same turn, while the frames tick.
/// (e) A close taken back in a later frame turn starts from what shows: the width path does not jump.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabMovesOnTheFrameClockTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    static let refresh = 1.0 / 120

    /// A strip of three tabs in a window on screen, the window's scheduler ticking under an active frame client.
    final class Rig {
        let model: TabStripModel
        let strip: TabStripView
        let window: NSWindow
        let scheduler: FrameScheduler
        private var client: FrameClient?
        private let animations: Set<MotionKind>

        init() throws {
            let tabs = (0..<3).map { TabItem(id: TabID("tab\($0)"), title: "Tab \($0)") }
            model = TabStripModel(tabs: tabs, selectedID: TabID("tab0"))
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            strip = TabStripView(model: model)
            strip.frame = NSRect(x: 0, y: 0, width: 600, height: TabStripView.preferredHeight)
            window.contentView = strip
            window.orderFrontRegardless()
            scheduler = FrameScheduler.forWindow(window)
            Motion.reduceMotionOverride = false
            // Closing tabs share the structural `newTab` motion switch (TabCloseWidthChangeTests).
            animations = DesignSettings.shared.enabledAnimations
            DesignSettings.shared.enabledAnimations.insert(.newTab)
            try #require(window.screen != nil)
            strip.layoutSubtreeIfNeeded()
            try #require(Motion.tabs.animatesMovement, "animation speed is off on this host")
            let client = FrameClient(owner: "TabMovesOnTheFrameClockTests", on: scheduler) { _ in true }
            client.activate()
            self.client = client
        }

        /// One display frame whose target (the time it shows) is `target`, given by hand as the link gives one.
        func frame(showingAt target: CFTimeInterval) {
            scheduler.frameDidFire(timestamp: target - TabMovesOnTheFrameClockTests.refresh, refreshInterval: TabMovesOnTheFrameClockTests.refresh)
        }

        func cell(_ index: Int) throws -> TabCell { try #require(strip.cells[TabID("tab\(index)")]) }

        /// Closes the last tab (the model change and the strip's sync, one event turn).
        func closeLast() {
            model.tabs.removeLast()
            strip.sync(fromModel: true)
        }

        func close() {
            client?.deactivate()
            client = nil
            Motion.reduceMotionOverride = nil
            DesignSettings.shared.enabledAnimations = animations
            window.closeAfterTest()
        }
    }

    /// The close's tween: its duration and its progress at `seconds` into it.
    static func closeTween() throws -> (duration: CFTimeInterval, progress: (CFTimeInterval) -> CGFloat) {
        let move = try #require(MotionMove.tween(.tabClose, in: Motion.tabs))
        let ease = MotionPath.Ease(MotionTween.tabClose.timingFunction)
        return (move.duration, { MotionPath.ease(ease, $0 / move.duration) })
    }

    /// (a) The closing cell's width at each later frame time is the tween at that time minus the origin.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aCloseWhileFramesTickShowsTheTweenAtTheFrameClocksTime() throws {
        let rig = try Rig()
        defer { rig.close() }
        let tween = try Self.closeTween()
        let origin = CACurrentMediaTime() - 0.05
        rig.frame(showingAt: origin)
        let closing = try rig.cell(2)
        let from = closing.layer.bounds.width
        rig.closeLast()
        try #require(rig.strip.dying.contains(TabID("tab2")), "the close did not animate")
        let to = closing.layer.bounds.width
        try #require(abs(from - to) > 4, "the close did not change the closing tab's width (\(from) to \(to))")
        let path = MotionPath(closing.layer, "bounds.size")
        #expect(path.isExact)
        var off: [String] = []
        for k in 1...Int((tween.duration / Self.refresh).rounded(.down)) {
            let t = origin + Double(k) * Self.refresh
            let expected = from + (to - from) * tween.progress(t - origin)
            let shown = path.value(at: t).x
            if abs(shown - expected) > 0.5 { off.append("frame \(k): \(shown), the tween at the frame clock's time is \(expected)") }
        }
        #expect(off.isEmpty, "\(off.count) frames off the frame clock: \(off.prefix(3))")
    }

    /// (b) An origin ahead of now: the moves begin there and fill backward, so no frame shows the end value first.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func anOriginAheadOfNowShowsTheStartUntilTheMoveBegins() throws {
        let rig = try Rig()
        defer { rig.close() }
        let now = CACurrentMediaTime()
        let origin = now + 0.006
        rig.frame(showingAt: origin)
        let closing = try rig.cell(2)
        let from = closing.layer.bounds.width
        rig.closeLast()
        try #require(rig.strip.dying.contains(TabID("tab2")), "the close did not animate")
        let moves = (closing.layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) }
            .compactMap { closing.layer.animation(forKey: $0) }
        try #require(!moves.isEmpty, "the close added no move to the closing tab")
        for move in moves {
            let begin = closing.layer.convertTime(move.beginTime, to: nil)
            #expect(abs(begin - origin) < 0.0005, "a move begins at \(begin - now) s from now, not at the frame clock's origin (\(origin - now) s)")
            #expect(move.fillMode == .backwards || move.fillMode == .both, "a move that begins ahead of now does not fill backward (\(move.fillMode))")
        }
        let shown = MotionPath(closing.layer, "bounds.size").value(at: now).x
        #expect(abs(shown - from) < 0.5, "before the move begins the closing tab shows \(shown), not its start width \(from)")
    }

    /// (c) The closing tab goes when the motion it shows ends: the origin plus the close's duration.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() },
          arguments: [0.0, 0.05])
    func theClosingTabGoesWhenTheMotionItShowsEnds(behind: Double) throws {
        let rig = try Rig()
        defer { rig.close() }
        let tween = try Self.closeTween()
        let origin = CACurrentMediaTime() - behind
        rig.frame(showingAt: origin)
        rig.closeLast()
        try #require(rig.strip.dying.contains(TabID("tab2")), "the close did not animate")
        let goes = try #require(rig.strip.goesAt[TabID("tab2")])
        #expect(abs(goes - (origin + tween.duration)) < 0.002,
                "the closing tab goes at \(goes - origin) s after the frame clock's origin, its motion ends at \(tween.duration) s")
    }

    /// (d) Reduce Motion while the frames tick: the close lands at once and the tab goes in the same turn.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func reduceMotionLandsTheCloseAtOnceWhileFramesTick() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.frame(showingAt: CACurrentMediaTime() - 0.02)
        Motion.reduceMotionOverride = true
        rig.closeLast()
        #expect(rig.strip.dying.isEmpty, "a close under Reduce Motion animated")
        #expect(rig.strip.cells[TabID("tab2")] == nil, "the closed tab did not go in the close's turn")
        let moves = rig.strip.cells.values.flatMap { $0.layer.animationKeys() ?? [] }.filter { $0.hasPrefix(TabStripMove.keyPrefix) }
        #expect(moves.isEmpty, "Reduce Motion left strip moves: \(moves)")
    }

    /// (e) The close taken back three frames later: the width path at the take-back's own origin is what showed there
    /// before it, and from there it moves back to the full width with no jump.
    @Test(.enabled("a window with no screen applies its changes at once") { await Self.hasDisplay() })
    func aCloseTakenBackStartsFromWhatShows() throws {
        let rig = try Rig()
        defer { rig.close() }
        let origin = CACurrentMediaTime() - 0.05
        rig.frame(showingAt: origin)
        let closing = try rig.cell(2)
        let full = closing.layer.bounds.width
        let item = try #require(rig.model.tabs.last)
        rig.closeLast()
        try #require(rig.strip.dying.contains(TabID("tab2")), "the close did not animate")
        let second = origin + 3 * Self.refresh
        let before = MotionPath(closing.layer, "bounds.size")
        rig.frame(showingAt: second)
        rig.model.tabs.append(item)
        rig.strip.sync(fromModel: true)
        let cell = try rig.cell(2)
        let after = MotionPath(cell.layer, "bounds.size")
        let end = try #require(after.end)
        let times = MotionPath.times(from: second, to: end, count: MotionPath.sampleCount(seconds: end - second))
        #expect(abs(after.value(at: second).x - before.value(at: second).x) < 0.5,
                "the take-back shows \(after.value(at: second).x) at its origin, the close showed \(before.value(at: second).x) there")
        var jumps: [String] = []
        for (a, b) in zip(times, times.dropFirst()) {
            let step = abs(after.value(at: b).x - after.value(at: a).x)
            if step > full / 4 { jumps.append("\(a - second) s: \(step) pt in one frame") }
        }
        #expect(jumps.isEmpty, "the take-back jumps: \(jumps.prefix(3))")
        #expect(abs(after.value(at: end).x - full) < 0.5, "the take-back ends at \(after.value(at: end).x), not the full width \(full)")
    }
}

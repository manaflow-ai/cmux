import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeups
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S2 (timing): every spring of a window shows in each frame the value of its curve at the
/// time that frame shows, the display link's `targetTimestamp`. The window's
/// clock stepped its springs by the time between the vsyncs that started the frames (`CADisplayLink.timestamp`),
/// clamped to 1/30 s, which is off the curve in two cases:
/// - The refresh period changes mid-motion (ProMotion at 120 or 60 Hz, a window moved to a 60 Hz display, Low Power
///   Mode). A frame that shows 1/60 s after its vsync stepped by the 1/120 s the frame before it took: every frame
///   after the change showed the curve a refresh behind (or ahead), for the rest of the motion.
/// - A late frame: the main thread missed refreshes (film pp-drag-browser, cmux22 120 Hz: 45 display-link ticks in
///   1205 ms, gaps of 35-44 ms). A gap over 33 ms stepped the springs by 33 ms only, so the motion fell behind its
///   curve and stayed behind; Chrome advances an animation to its frame's time.
/// The first frame of a motion from rest shows one refresh of it (`FrameSchedulerFirstTickTests`): the curve starts
/// at that frame's vsync. The test is the display link: it fires the window's scheduler with the link's timestamp
/// and the period until the frame shows (`targetTimestamp - timestamp`), as `FrameScheduler.tick` does.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct MotionClockFrameTimeTests {
    /// One spring on the window's clock, stepped as the clock steps every chrome spring (closed form, no settle).
    final class Probe: MotionAnimating {
        static let travel: CGFloat = 300
        let parameters = SpringParameters(response: 0.3, dampingFraction: 1)
        var spring = SpringValue(0)

        init() { spring.target = Self.travel }

        func motionStep(_ dt: Double) -> Bool {
            spring.step(dt, parameters: parameters)
            return true
        }

        /// The spring's curve `time` seconds after its motion began.
        func curve(at time: Double) -> CGFloat {
            let solved = SpringValue.solve(displacement: -Double(Self.travel), velocity: 0, time: time, parameters: parameters)
            return Self.travel + CGFloat(solved.displacement)
        }
    }

    /// A late display frame: the link fires `refreshes` refreshes after the frame before it.
    nonisolated struct Late: Sendable, CustomTestStringConvertible {
        var refresh: Double
        var refreshes: Int
        var testDescription: String { "\(Int((1 / refresh).rounded())) Hz, \(refreshes) refreshes late" }
    }

    /// A window that is never ordered in (a window never on screen is not judged out of sight): its scheduler ticks
    /// only when the test fires it.
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Fires one frame per entry of `frames` (the link's timestamp and the period until the frame shows) and returns
    /// each frame the spring showed off its curve at the time the frame shows, less the time the motion `paused` for
    /// before that frame (a hang: none by default).
    static func misses(_ frames: [(vsync: CFTimeInterval, refresh: Double)], paused: (Int) -> Double = { _ in 0 }) -> [String] {
        let window = Self.window()
        defer { window.closeAfterTest() }
        let probe = Probe()
        let clock = MotionClock.forWindow(window)
        clock.run(probe, trace: "test.frame-time")
        defer { clock.stop(probe) }
        let scheduler = FrameScheduler.forWindow(window)
        // The first frame shows one refresh of the motion: the curve starts at its vsync.
        let origin = frames.first?.vsync ?? 0
        var misses: [String] = []
        for (index, frame) in frames.enumerated() {
            scheduler.frameDidFire(timestamp: frame.vsync, refreshInterval: frame.refresh)
            let shows = frame.vsync + frame.refresh
            let curve = probe.curve(at: shows - origin - paused(index))
            let shown = probe.spring.value
            if abs(shown - curve) > 0.001 {
                let at = String(format: "%.2f", (shows - origin) * 1_000)
                misses.append("frame \(index) shows at +\(at) ms: \(String(format: "%.3f", shown)) pt, its curve \(String(format: "%.3f", curve)) pt")
            }
        }
        return misses
    }

    /// Frames back to back at `periods` (each vsync is when the frame before it showed), from 1000 s.
    static func backToBack(_ periods: [Double]) -> [(vsync: CFTimeInterval, refresh: Double)] {
        var vsync: CFTimeInterval = 1_000
        return periods.map { refresh in
            defer { vsync += refresh }
            return (vsync: vsync, refresh: refresh)
        }
    }

    @Test(arguments: [[120.0, 60, 120], [60.0, 120]])
    func everyFrameShowsTheCurveAtTheTimeItShowsAcrossARefreshChange(rates: [Double]) {
        // Four frames at each rate: each change comes mid-motion.
        let periods = rates.flatMap { Array(repeating: 1 / $0, count: 4) }
        let misses = Self.misses(Self.backToBack(periods))
        #expect(misses.isEmpty, "\(rates) Hz: frames off the spring's curve at the time they show:\n\(misses.joined(separator: "\n"))")
    }

    @Test(arguments: [Late(refresh: 1.0 / 60, refreshes: 3), Late(refresh: 1.0 / 120, refreshes: 5)])
    func aLateFrameLandsOnTheCurveNotBehindIt(_ late: Late) {
        // Three frames on time, one that comes `refreshes` refreshes after the frame before it (the main thread
        // missed the refreshes between), three on time again.
        var frames = Self.backToBack(Array(repeating: late.refresh, count: 3))
        var vsync = (frames.last?.vsync ?? 1_000) + Double(late.refreshes) * late.refresh
        for _ in 0..<4 {
            frames.append((vsync: vsync, refresh: late.refresh))
            vsync += late.refresh
        }
        let misses = Self.misses(frames)
        #expect(misses.isEmpty, "\(late.testDescription): frames off the spring's curve at the time they show:\n\(misses.joined(separator: "\n"))")
    }

    /// A frame after a gap longer than `FrameScheduler.catchUpLimit` (0.1 s: a main-thread hang, since a frame comes at
    /// least that often while the main thread runs) moves the motion by that limit: not the whole gap (a jump), not
    /// 1/30 s (behind). The motion pauses for the rest of the gap and goes on along its curve from there.
    @Test func aFrameAfterAHangMovesTheMotionByTheCatchUpLimit() {
        let refresh = 1.0 / 120, gap = 0.5, limit = 0.1
        // Three frames on time, one `gap` after the frame before it, three on time again.
        var frames = Self.backToBack(Array(repeating: refresh, count: 3))
        var vsync = (frames.last?.vsync ?? 1_000) + gap
        for _ in 0..<4 {
            frames.append((vsync: vsync, refresh: refresh))
            vsync += refresh
        }
        let misses = Self.misses(frames) { $0 >= 3 ? gap - limit : 0 }
        #expect(misses.isEmpty, "a \(gap) s gap: frames off the spring's curve paused for \(gap - limit) s:\n\(misses.joined(separator: "\n"))")
    }
}

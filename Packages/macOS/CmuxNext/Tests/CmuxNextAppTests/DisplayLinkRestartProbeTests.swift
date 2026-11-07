import AppKit
import CmuxNextTestSupport
import QuartzCore
import Testing

/// RESIZE P0 2 diagnostic (not for merge): how a window display link's first ticks fall after a restart. A window's
/// FrameScheduler drops its link when idle and makes a new one for the next motion (a key resize press); this compares
/// that with a link kept paused and unpaused. Prints LINKPROBE lines: the delay from the restart to the first callback,
/// the first tick's phase on the refresh grid the link had before, and the first intervals.
@MainActor
@Suite(.serialized, .closesItsWindows, .enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
struct DisplayLinkRestartProbeTests {
    final class Recorder: NSObject {
        var ticks: [(callback: CFTimeInterval, timestamp: CFTimeInterval, target: CFTimeInterval)] = []
        @objc func tick(_ link: CADisplayLink) {
            ticks.append((CACurrentMediaTime(), link.timestamp, link.targetTimestamp))
        }
    }

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.orderFrontRegardless()
        return window
    }

    static func link(_ window: NSWindow, _ recorder: Recorder) -> CADisplayLink {
        // concurrency-allow: a diagnostic test's own display link
        let link = window.displayLink(target: recorder, selector: #selector(Recorder.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        return link
    }

    static func report(_ kind: String, round: Int, before: Recorder, after: Recorder, restart: CFTimeInterval) {
        guard let last = before.ticks.last, before.ticks.count > 2, let first = after.ticks.first else {
            print("LINKPROBE \(kind) round=\(round) no ticks before=\(before.ticks.count) after=\(after.ticks.count)")
            return
        }
        let refresh = last.target - last.timestamp
        let phase = (first.timestamp - last.timestamp).truncatingRemainder(dividingBy: refresh)
        let ms = { (v: Double) in String(format: "%.2f", v * 1_000) }
        let intervals = zip(after.ticks.dropFirst(), after.ticks).prefix(5).map { ms($0.timestamp - $1.timestamp) }
        let callbacks = zip(after.ticks.dropFirst(), after.ticks).prefix(5).map { ms($0.callback - $1.callback) }
        print("LINKPROBE \(kind) round=\(round) refresh=\(ms(refresh)) first_callback_after_restart=\(ms(first.callback - restart))"
              + " first_ts_minus_restart=\(ms(first.timestamp - restart)) first_ts_grid_phase=\(ms(phase))"
              + " intervals=\(intervals.joined(separator: ",")) callback_gaps=\(callbacks.joined(separator: ","))")
    }

    @Test func aNewLinkAndAnUnpausedLinkFirstTicks() async throws {
        let window = Self.window()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        for round in 0..<6 {
            // A new link after an idle drop (FrameScheduler.pause today).
            let before = Recorder()
            let old = Self.link(window, before)
            try await Task.sleep(for: .milliseconds(250))
            old.invalidate()
            try await Task.sleep(for: .milliseconds(300 + 37 * round))
            let after = Recorder()
            let restart = CACurrentMediaTime()
            let made = Self.link(window, after)
            try await Task.sleep(for: .milliseconds(250))
            made.invalidate()
            Self.report("new", round: round, before: before, after: after, restart: restart)

            // One link kept, paused while idle.
            let kept = Recorder()
            let link = Self.link(window, kept)
            try await Task.sleep(for: .milliseconds(250))
            link.isPaused = true
            let paused = kept.ticks
            try await Task.sleep(for: .milliseconds(300 + 37 * round))
            let resumed = Recorder()
            kept.ticks = []
            let restartKept = CACurrentMediaTime()
            link.isPaused = false
            try await Task.sleep(for: .milliseconds(250))
            link.invalidate()
            let beforeKept = Recorder()
            beforeKept.ticks = paused
            resumed.ticks = kept.ticks
            Self.report("unpaused", round: round, before: beforeKept, after: resumed, restart: restartKept)
        }
    }
}

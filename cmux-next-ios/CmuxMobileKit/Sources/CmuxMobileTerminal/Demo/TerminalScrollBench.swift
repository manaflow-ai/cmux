#if os(iOS) && DEBUG
import Foundation
import os
import QuartzCore
import UIKit

/// DEBUG only: the scroll round trip against a real paired Mac (cmux#48951).
/// Post `dev.cmux.mobile.scrollbench.tui` (a full-screen app: the fling is the
/// wheel) or `dev.cmux.mobile.scrollbench.page` (a bare shell: the page's own
/// fling) with `xcrun simctl spawn UDID notifyutil -p NAME`. The terminal on
/// screen flings up and down 3 times each; the result line goes to the
/// `dev.cmux.mobile:scrollbench` log and `Documents/scrollbench.txt`:
/// frame intervals, and for each wheel report the time to the Mac's first
/// output after it and to the first present after that output.
@MainActor
enum TerminalScrollBench {
    static weak var target: TerminalViewController?
    private static var installed = false
    private static var running = false
    static let logger = Logger(subsystem: "dev.cmux.mobile", category: "scrollbench")

    static func install(_ controller: TerminalViewController) {
        target = controller
        guard !installed else { return }
        installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in ["dev.cmux.mobile.scrollbench.tui", "dev.cmux.mobile.scrollbench.page"] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                let full = (name?.rawValue as String?)?.hasSuffix(".tui") ?? false
                Task { @MainActor in await TerminalScrollBench.run(full: full) }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    static func run(full: Bool) async {
        guard !running, let controller = target else { return }
        running = true
        defer { running = false }
        let clock = ContinuousClock()
        func wait(_ s: Double) async { try? await clock.sleep(for: .milliseconds(Int(s * 1000))) }
        controller.rttLog.reset()
        let sampler = ScrollBenchFrameSampler()
        sampler.start()
        for _ in 0..<3 {
            if full { controller.tuiFling(velocity: 3000) } else { controller.fling(velocity: -5000) }
            await wait(1.6)
            if full { controller.tuiFling(velocity: -3000) } else { controller.fling(velocity: 5000) }
            await wait(1.6)
        }
        await wait(0.5)
        let line = "scrollbench \(full ? "tui" : "page") \(controller.title ?? "-") " + sampler.stop() + " " + controller.rttLog.summary()
        logger.notice("\(line, privacy: .public)")
        print("[scrollbench] \(line)")
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = documents.appendingPathComponent("scrollbench.txt")
            let text = String(format: "%.3f %@\n", Date().timeIntervalSince1970, line)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
            } else { try? Data(text.utf8).write(to: url) }
            try? controller.rttLog.raw().write(to: documents.appendingPathComponent("scrollbench-\(full ? "tui" : "page")-raw.txt"), atomically: true, encoding: .utf8)
        }
    }
}

/// Wheel report -> the Mac's next output -> the next present.
@MainActor
final class TerminalScrollRTT {
    private var pending: [CFTimeInterval] = []
    private var replied: [(sent: CFTimeInterval, rx: CFTimeInterval)] = []
    private var toReply: [Double] = []
    private var toPresent: [Double] = []
    /// The first report of a burst (none in the 250 ms before): no earlier report's reply can answer it.
    private var firstToPresent: [Double] = []
    private var firstSends: Set<CFTimeInterval> = []
    private var lastSend: CFTimeInterval = 0
    private(set) var sends = 0
    private var bytes = 0
    private var events: [String] = []

    func reset() {
        pending = []; replied = []; toReply = []; toPresent = []; firstToPresent = []; firstSends = []
        lastSend = 0; sends = 0; bytes = 0; events = []
    }

    func wheelSent() {
        let now = CACurrentMediaTime()
        if now - lastSend > 0.25 { firstSends.insert(now) }
        lastSend = now
        pending.append(now)
        sends += 1
        events.append(String(format: "%.4f wheel", now))
    }

    func outputArrived(bytes count: Int) {
        let now = CACurrentMediaTime()
        bytes += count
        events.append(String(format: "%.4f rx %d", now, count))
        for sent in pending {
            toReply.append((now - sent) * 1000)
            replied.append((sent, now))
        }
        pending.removeAll()
    }

    func presented() {
        guard !replied.isEmpty else { return }
        let now = CACurrentMediaTime()
        events.append(String(format: "%.4f present", now))
        for pair in replied {
            let ms = (now - pair.sent) * 1000
            toPresent.append(ms)
            if firstSends.contains(pair.sent) { firstToPresent.append(ms) }
        }
        replied.removeAll()
    }

    func summary() -> String {
        func stats(_ values: [Double]) -> String {
            let s = values.sorted()
            guard !s.isEmpty else { return "n=0" }
            func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
            return String(format: "n=%d p50=%.1f p95=%.1f max=%.1f", s.count, pct(0.5), pct(0.95), s.last ?? 0)
        }
        return "wheel=\(sends) unanswered=\(pending.count) rxbytes=\(bytes) toReply[\(stats(toReply))] toPresent[\(stats(toPresent))] firstOfFling[\(stats(firstToPresent))]"
    }

    func raw() -> String { events.joined(separator: "\n") }
}

@MainActor
final class ScrollBenchFrameSampler: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let top = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: top, maximum: top, preferred: top)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
    }

    func stop() -> String {
        link?.invalidate()
        link = nil
        let sorted = intervals.sorted()
        guard !sorted.isEmpty else { return "frames=0" }
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let frame = 1000 / Double(max(60, UIScreen.main.maximumFramesPerSecond))
        let hitches = sorted.filter { $0 > frame * 1.5 }.count
        return String(format: "frames=%d p50=%.2f p95=%.2f max=%.2f hitches=%d", sorted.count, pct(0.5), pct(0.95), sorted.last ?? 0, hitches)
    }
}
#endif

#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Drag-to-scroll latency in less (Leo, 2026-11-12, on less and man no longer
/// scrolling on the phone: "Okay. But can't we do something here?"). less's
/// modes go into a real Ghostty mirror surface, and no program name is set
/// or read anywhere; then 60 times a one-row wheel at the finger
/// through ``TerminalSurfaceView/scrollWheel(at:deltaY:momentum:)`` (the call
/// a drag makes), timed until its key reaches `onInput`, the bytes the
/// session sends to the Mac. A wheel that gets no byte in 250 ms is a miss:
/// the drag did not scroll less at all.
@MainActor
@Suite(.serialized) struct TerminalDragLatencyTests {
    @MainActor final class Sink { var sent = Data() }

    @Test func dragToScrollLatencyInLess() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let surface = TerminalSurfaceView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        window.isHidden = false
        window.addSubview(surface)
        let sink = Sink()
        surface.onInput = { [sink] data in sink.sent.append(data) }
        try #require(surface.surface != nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            surface.feed(Data("\u{1b}[?1049h\u{1b}[?1h\u{1b}=".utf8), completion: { done.resume() })
        }
        sink.sent = Data()
        let row = surface.cellSize.height
        let thumb = CGPoint(x: surface.gridPadding.x + 4.5 * surface.cellSize.width,
                            y: surface.gridPadding.y + (Double(max(1, surface.grid.rows)) - 0.5) * row)
        var samples: [Duration] = []
        var missed = 0
        for _ in 0..<60 {
            let before = sink.sent.count
            let start = ContinuousClock.now
            surface.scrollWheel(at: thumb, deltaY: row * 1.01, momentum: .none)
            let deadline = start.advanced(by: .milliseconds(250))
            while sink.sent.count == before, ContinuousClock.now < deadline { await Task.yield() }
            if sink.sent.count == before { missed += 1 } else { samples.append(ContinuousClock.now - start) }
        }
        samples.sort()
        func ms(_ d: Duration?) -> String {
            guard let d else { return "never" }
            return String(format: "%.3f", Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15)
        }
        let p50 = samples.isEmpty ? nil : samples[samples.count / 2]
        let p95 = samples.isEmpty ? nil : samples[min(samples.count - 1, samples.count * 95 / 100)]
        let line = "drag-latency less wheels=60 scrolled=\(samples.count) missed=\(missed) p50_ms=\(ms(p50)) p95_ms=\(ms(p95)) max_ms=\(ms(samples.last)) bytes=\(sink.sent.count)"
        print(line)
        Attachment.record(line, named: "drag-latency-less.txt")
        Self.check(missed: missed)
    }

    /// Every wheel scrolled less: one key each.
    static func check(missed: Int) { #expect(missed == 0) }
}
#endif

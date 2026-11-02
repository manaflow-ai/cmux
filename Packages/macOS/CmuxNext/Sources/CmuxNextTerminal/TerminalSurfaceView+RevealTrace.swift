#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import IOSurface
import QuartzCore

/// NEVER MERGE (SWITCH FRAMES SF-2 diagnosis, test/switch-reveal-trace-feat): what a terminal shows when a
/// switch shows it again. Per reveal (``TerminalSurfaceView/updateOcclusion()`` turning drawing on): its host
/// time (CACurrentMediaTime, the recorder's clock), whether a volatile hidden frame existed, whether the layer
/// is empty after the reclaim (a purged frame), the ink of the frame on the layer then, and each of the next
/// presented frames (time, ink, empty layer) for 40 ticks. Ink = sampled pixels that differ from the frame's
/// top-left pixel: a full beacon frame has thousands, an empty screen with a cursor a few dozen.
@MainActor
final class TerminalRevealTrace {
    private weak var view: TerminalSurfaceView?
    private(set) var rows: [[String: Double]] = []
    private var current: [String: Double]?
    private var lastShown: AnyObject?
    private var ticks = 0
    private var seen = 0
    private lazy var frames = FrameClient(owner: "TerminalRevealTrace", isAnimation: false, scheduler: { [weak self] in
        self?.view.map(FrameScheduler.forView) ?? .app
    }) { [weak self] tick in self?.tick(tick) ?? false }

    init(view: TerminalSurfaceView) { self.view = view }

    func revealed(hadVolatile: Bool, contentsNil: Bool) {
        finish()
        let shown = view?.layer?.contents as AnyObject?
        lastShown = shown
        ticks = 0
        seen = 0
        current = ["t": CACurrentMediaTime(), "had_volatile": hadVolatile ? 1 : 0, "contents_nil": contentsNil ? 1 : 0,
                   "ink": Double(Self.ink(view?.presentedFrame))]
        frames.activate()
    }

    private func tick(_ tick: FrameTick) -> Bool {
        guard current != nil, let view else { return false }
        ticks += 1
        let shown = view.layer?.contents as AnyObject?
        if shown !== lastShown {
            lastShown = shown
            seen += 1
            current?["f\(seen)_t"] = CACurrentMediaTime()
            current?["f\(seen)_tick"] = tick.timestamp
            current?["f\(seen)_ink"] = Double(Self.ink(view.presentedFrame))
            current?["f\(seen)_nil"] = shown == nil ? 1 : 0
        }
        if ticks >= 40 || seen >= 6 {
            finish()
            return false
        }
        return true
    }

    private func finish() {
        guard var row = current else { return }
        row["ticks"] = Double(ticks)
        row["surface"] = Double(UInt(bitPattern: view.map { ObjectIdentifier($0).hashValue } ?? 0) % 1_000_000_007)
        rows.append(row)
        if rows.count > 512 { rows.removeFirst(rows.count - 512) }
        current = nil
        // This surface's reveals as one JSON array in $TMPDIR/cmux-reveal-trace-<pid>-<surface>.json, written off
        // the main thread (the journey reads them after the run; no App code, no socket method).
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-reveal-trace-\(ProcessInfo.processInfo.processIdentifier)-\(Int(row["surface"] ?? 0)).json")
        DispatchQueue.global(qos: .utility).async { try? data.blockingWrite(to: url, options: .atomic) }
    }

    static func ink(_ surface: IOSurface?) -> Int {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 0 else { return -1 }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let corner = (bytes[0], bytes[1], bytes[2])
        var differing = 0
        for y in stride(from: 0, to: surface.height, by: 4) {
            for x in stride(from: 0, to: surface.width, by: 4) {
                let pixel = bytes + y * surface.bytesPerRow + x * 4
                if abs(Int(pixel[0]) - Int(corner.0)) + abs(Int(pixel[1]) - Int(corner.1)) + abs(Int(pixel[2]) - Int(corner.2)) > 90 {
                    differing += 1
                }
            }
        }
        return differing
    }
}
#endif

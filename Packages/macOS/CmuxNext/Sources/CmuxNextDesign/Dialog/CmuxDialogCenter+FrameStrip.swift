#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// `debug.dialog_strip` (DEBUG builds): a dialog's open and close as the window server composited
/// them, frame after frame. The window and its overlay panel (where dialogs draw) are read back to
/// back off the main actor while `spec` opens in `window` and, `holdMs` later, closes (`close`:
/// `escape`, `return` or `press:<button>`), through the same center path a key or click takes.
///
/// Per phase (`open`, `close`) the report has every frame's `ms` from the phase's start, its `card`
/// and `scrim` progress (0 at the frame before the phase, 1 at its settled frame: the mean color
/// distance inside the dialog's rect and outside it), `intermediate` (frames between the two
/// states), `settled_ms`, `max_jump` (the largest progress step between two frames: a cut reads
/// near 1) and `main_ms` (the main actor's time to present or close). PNGs of every frame and a strip
/// per phase go to `dir`. Never changes app focus.
extension CmuxDialogCenter {
    public func frameStrip(_ spec: CmuxDialogSpec, in window: NSWindow, close: String, leadMs: Double, holdMs: Double,
                           tailMs: Double, scale: Double, dir: String) async -> [String: Any] {
        guard window.windowNumber > 0, let screen = NSScreen.screens.first else { return ["error": "no window"] }
        // Global display coordinates, top-left origin, as the window server reads them.
        let frame = window.frame
        let bounds = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let number = CGWindowID(window.windowNumber)
        let start = ContinuousClock.now
        // The recording is the measurement: it runs at the priority of the request that waits for it.
        let recording = Task.detached(priority: WorkPriority.userBlocking.taskPriority) {
            await WindowFrame.recordAbove(number, bounds: bounds, scale: scale, from: start, until: leadMs + holdMs + tailMs)
        }

        await Self.pause(leadMs)
        let openedAt = Self.ms(since: start)
        let id = present(spec, in: .window(window)) { _ in }
        let presentMs = Self.ms(since: start) - openedAt
        // The card's rect in window points, top-left origin (frames are scaled below).
        let cardPoints = view(id).map { view -> CGRect in
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
        }

        await Self.pause(holdMs)
        let closedAt = Self.ms(since: start)
        if close.hasPrefix("press:") {
            _ = press(id, button: String(close.dropFirst("press:".count)))
        } else {
            _ = key(close == "return" ? .return : .escape, in: id)
        }
        let closeMs = Self.ms(since: start) - closedAt
        // A close the keys did not answer must not leave the dialog up.
        _ = dismiss(id)

        let frames = await recording.value
        guard let cardPoints, let first = frames.first, frames.count > 2 else { return ["error": "no frames", "frame_count": frames.count] }
        // A frame is the window's backing pixels times `scale`: its own width says how many per point.
        let perPoint = Double(first.width) / frame.width
        let card = CGRect(x: cardPoints.minX * perPoint, y: cardPoints.minY * perPoint,
                          width: cardPoints.width * perPoint, height: cardPoints.height * perPoint)
        let open = await Self.phase("open", frames, from: openedAt, to: closedAt, card: card, dir: dir)
        let closing = await Self.phase("close", frames, from: closedAt, to: .infinity, card: card, dir: dir)
        let intervals = zip(frames.dropFirst(), frames).map { $0.milliseconds - $1.milliseconds }
        return [
            "dir": dir, "frame_count": frames.count,
            "open": open?.report(mainMs: presentMs) ?? ["error": "no frames"], "close": closing?.report(mainMs: closeMs) ?? ["error": "no frames"],
            "mean_interval_ms": intervals.reduce(0, +) / Double(max(1, intervals.count)), "max_interval_ms": intervals.max() ?? 0,
            "card": [card.minX, card.minY, card.width, card.height],
        ]
    }

    /// One phase's frames, measured: `ms` from the phase's start, card and scrim progress, PNG name.
    private nonisolated struct Phase: Sendable {
        var rows: [(ms: Double, card: Double, scrim: Double, file: String)] = []
        var intermediate = 0, maxJump = 0.0
        var settledAt: Double?

        func report(mainMs: Double) -> [String: Any] {
            let round = { (value: Double) in (value * 1000).rounded() / 1000 }
            return ["frames": rows.map { ["ms": $0.ms, "card": round($0.card), "scrim": round($0.scrim), "file": $0.file] },
                    "intermediate": intermediate, "max_jump": round(maxJump), "main_ms": mainMs,
                    "settled_ms": settledAt.map { $0 as Any } ?? NSNull()]
        }
    }

    /// One phase, from the last frame before `from` to the last before `to`; measured and written
    /// off the main actor.
    @concurrent private static func phase(_ name: String, _ frames: [WindowFrame], from: Double, to: Double,
                                          card: CGRect, dir: String) async -> Phase? {
        guard let first = frames.lastIndex(where: { $0.milliseconds < from }),
              let last = frames.lastIndex(where: { $0.milliseconds < to }), last > first else { return nil }
        let slice = Array(frames[first...last])
        let before = slice[0], settled = slice[slice.count - 1]
        let cardSpan = max(1, settled.meanDistance(from: before, within: card))
        let scrimSpan = max(1, settled.meanDistance(from: before, excluding: card))
        try? FileManager.checked.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let files = WindowFrame.writeEach(slice, prefix: name, in: dir)
        var phase = Phase()
        for (index, frame) in slice.enumerated() {
            let ms = (frame.milliseconds - from).rounded()
            let cardProgress = frame.meanDistance(from: before, within: card) / cardSpan
            let scrimProgress = frame.meanDistance(from: before, excluding: card) / scrimSpan
            if (0.03...0.97).contains(cardProgress) { phase.intermediate += 1 }
            if let previous = phase.rows.last { phase.maxJump = max(phase.maxJump, abs(cardProgress - previous.card)) }
            if abs(cardProgress - 1) > 0.03 { phase.settledAt = nil } else if phase.settledAt == nil, index > 0 { phase.settledAt = ms }
            phase.rows.append((ms, cardProgress, scrimProgress, files[index]))
        }
        WindowFrame.writeStrip(slice, to: (dir as NSString).appendingPathComponent("\(name)-strip.png"))
        return phase
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    private static func pause(_ milliseconds: Double) async {
        let timer = DemandTimer(owner: "debug.dialog_strip.pause")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            timer.schedule(after: .milliseconds(Int(milliseconds))) { @MainActor in done.resume() }
        }
        // Held to here: freed before it fired, the timer would cancel itself and the await never end.
        withExtendedLifetime(timer) {}
    }
}
#endif

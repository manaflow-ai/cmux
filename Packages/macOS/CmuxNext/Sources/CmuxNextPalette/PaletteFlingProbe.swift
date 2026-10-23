#if DEBUG
import AppKit
import CmuxNextWakeups

/// Flings the open palette's list from inside the app: on each frame of the window's frame clock
/// (a ``FrameClient``), it checks that hover is on the row under a resting pointer, then scrolls a
/// fixed distance (turning at either end). A fleet host gives the app no real pointer or wheel
/// input (its worker has no Post Event grant), so the pointer is a stand-in location the list's
/// hover hit test reads (``PaletteListView/debugPointerInWindow``), and the scroll goes through
/// the clip view as a wheel scroll does, which runs the list's per-scroll hover path unchanged.
@MainActor
final class PaletteFlingProbe {
    private let content: PaletteContentView
    private let duration: CFTimeInterval
    private let pointsPerFrame: CGFloat
    private let pointer: NSPoint
    private var client: FrameClient?
    private var continuation: CheckedContinuation<PaletteFlingReport, Never>?
    private var report: PaletteFlingReport
    private var firstTimestamp: CFTimeInterval?
    private var lastTimestamp: CFTimeInterval?
    private var lastHover: String?
    private var direction: CGFloat = 1
    private var ticks = 0
    private var rendersAtStart = 0

    /// - Parameters:
    ///   - duration: How long to scroll, in seconds from the first frame. The fling ends on time,
    ///     not on a frame count, so a slow build (long frames) ends inside the caller's deadline
    ///     instead of running past it; the report counts the frames that really ran.
    ///   - pointsPerFrame: Points the list moves each frame.
    ///   - pointerFraction: Where the pointer rests, as a fraction of the list's height.
    init(content: PaletteContentView, duration: CFTimeInterval, pointsPerFrame: CGFloat, pointerFraction: CGFloat) {
        self.content = content
        self.duration = duration
        self.pointsPerFrame = pointsPerFrame
        let list = content.list
        let fraction = min(max(pointerFraction, 0.05), 0.95)
        pointer = list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.minY + list.bounds.height * fraction), to: nil)
        report = PaletteFlingReport(intervalsMs: [], refreshMs: 1000 / 60, workMs: [], scrolledPoints: 0,
                                    hoverChanges: 0, hoverMisses: 0, paletteRenders: 0)
    }

    /// Runs the fling and returns what it cost; a cancelled caller gets what was measured so far.
    func run() async -> PaletteFlingReport {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish() }
        }
    }

    private func start() {
        let list = content.list
        list.debugPointerInWindow = pointer
        rendersAtStart = content.debugRenders
        lastHover = list.hoveredID
        let client = FrameClient(owner: "PaletteFlingProbe", view: list) { [weak self] tick in
            self?.frame(tick) ?? false
        }
        self.client = client
        client.activate()
    }

    /// One frame: hover check for the last scroll, then the next scroll. False ends the fling.
    private func frame(_ tick: FrameTick) -> Bool {
        let start = ContinuousClock.now
        if let lastTimestamp { report.intervalsMs.append((tick.timestamp - lastTimestamp) * 1000) }
        lastTimestamp = tick.timestamp
        let first = firstTimestamp ?? tick.timestamp
        firstTimestamp = first
        if let refresh = tick.refreshInterval { report.refreshMs = refresh * 1000 }
        let list = content.list
        // The previous frame's scroll moved rows under the pointer; its hover hop has run by now.
        if ticks > 0 {
            let hovered = list.hoveredID
            if hovered != lastHover {
                report.hoverChanges += 1
                lastHover = hovered
            }
            if hovered != list.debugRowID(atWindowPoint: pointer) { report.hoverMisses += 1 }
        }
        guard tick.timestamp - first < duration else {
            finish()
            return false
        }
        ticks += 1
        var moved = list.debugScroll(by: direction * pointsPerFrame)
        if moved == 0 {
            direction = -direction
            moved = list.debugScroll(by: direction * pointsPerFrame)
        }
        report.scrolledPoints += moved
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        report.workMs.append(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
        return true
    }

    private func finish() {
        client?.deactivate()
        client = nil
        content.list.debugPointerInWindow = nil
        report.paletteRenders = content.debugRenders - rendersAtStart
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: report)
    }
}
#endif

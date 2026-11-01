import Foundation

/// One thing a scanline crosses (a pane, a divider line, a gap) and where it is, in device
/// pixels along the scanline, before and after the animation. The elements of a scanline tile it.
struct ScanlineElement {
    let label: String
    let before: (start: Double, end: Double)
    let after: (start: Double, end: Double)
    /// A separator (a divider line, a column gap): its run is exactly this many pixels in every frame.
    let exactLength: Int?
}

/// Judges every captured frame of one animation along one scanline against the oracle: where
/// each boundary between two elements must be, from the declared spring and the start and end
/// layout (cmux-ad 2026-11-01, rule 2). Per frame: no pixel off the learned colors (no half-pixel
/// blend), the elements in order with no gap and no overlap, separators exactly their width,
/// each boundary within 1 device pixel of the curve, motion that never steps back nor passes the
/// target more than the spring declares, and the last frame exactly the final layout. A dropped
/// frame (a refresh with no new frame while the curve moved a pixel) fails too.
struct ScanlineJudge {
    let spring: DeclaredSpring
    let elements: [ScanlineElement]
    /// When the change was applied (host time, seconds).
    let trigger: Double
    /// The display's refresh period.
    let period: Double
    /// Each boundary at most this far (device pixels) from the curve. Written here, never raised.
    static let curveTolerance = 1.0
    /// An animation shows at least this many frames between its start and end layouts.
    static let minimumMotionFrames = 8

    struct Verdict {
        var failures: [String] = []
        var report: [String] = []
        var drops = 0
        var motionFrames = 0
    }

    func boundaries(at progress: Double) -> [Double] {
        elements.dropLast().map { $0.before.end + ($0.after.end - $0.before.end) * progress }
    }

    var startBoundaries: [Int] { elements.dropLast().map { Int($0.before.end.rounded()) } }
    var finalBoundaries: [Int] { elements.dropLast().map { Int($0.after.end.rounded()) } }

    /// `frames` are (time, scanline) pairs in time order; `palette` names the pixels.
    func judge(_ frames: [(time: Double, line: [UInt32])], palette: ScanlinePalette, animated: Bool) -> Verdict {
        var verdict = Verdict()
        let labels = elements.map(\.label)
        var valid: [(time: Double, boundaries: [Int])] = []
        for (index, frame) in frames.enumerated() where frame.time >= trigger - 3 * period {
            let runs = palette.runs(frame.line)
            let at = "frame \(index) (t=\(Self.ms(frame.time - trigger)) ms)"
            if let blend = runs.first(where: { $0.label == nil }) {
                let colors = frame.line[blend.start..<min(blend.end, blend.start + 4)].map(ScanlinePalette.hex)
                verdict.failures.append("\(at): \(blend.length) px at \(blend.start) match no pane, divider or gap color "
                    + "(\(colors.joined(separator: " "))): a blend, an edge off the pixel grid. Runs: \(runs)")
                continue
            }
            guard runs.map(\.label) == labels else {
                verdict.failures.append("\(at): runs \(runs), expected \(labels): a gap, an overlap or a missing element")
                continue
            }
            for (run, element) in zip(runs, elements) where element.exactLength.map({ $0 != run.length }) == true {
                verdict.failures.append("\(at): \(element.label) is \(run.length) px, not \(element.exactLength ?? 0)")
            }
            valid.append((frame.time, runs.dropLast().map(\.end)))
        }
        guard let last = valid.last, frames.last.map({ $0.time == last.time }) == true else {
            verdict.failures.append("the last captured frame is not a valid frame of the layout (\(frames.count) frames)")
            return verdict
        }
        if last.boundaries != finalBoundaries {
            verdict.failures.append("the last frame's boundaries are \(last.boundaries), the final layout's \(finalBoundaries)")
        }
        guard animated else { return judgeInstant(valid, verdict) }
        return judgeCurve(valid, verdict)
    }

    /// Animations off: every frame after the change is the start or the final layout, and once
    /// final it stays final.
    private func judgeInstant(_ valid: [(time: Double, boundaries: [Int])], _ verdict: Verdict) -> Verdict {
        var verdict = verdict, landed = false
        for frame in valid where frame.time >= trigger {
            if frame.boundaries == finalBoundaries {
                landed = true
            } else if landed || frame.boundaries != startBoundaries {
                verdict.failures.append("t=\(Self.ms(frame.time - trigger)) ms: boundaries \(frame.boundaries) are neither the start "
                    + "\(startBoundaries) nor the final \(finalBoundaries) layout with animations off")
            }
        }
        if !landed { verdict.failures.append("no frame after the change shows the final layout \(finalBoundaries)") }
        return verdict
    }

    private func judgeCurve(_ valid: [(time: Double, boundaries: [Int])], _ verdict: Verdict) -> Verdict {
        var verdict = verdict
        // One time origin for every boundary and frame, within a few frames of the change (input to display latency).
        var best = (origin: trigger, error: Double.infinity)
        var origin = trigger - 2 * period
        while origin <= trigger + 5 * period {
            let error = valid.map { maxError($0, origin: origin) }.max() ?? .infinity
            if error < best.error { best = (origin, error) }
            origin += 0.0001
        }
        let moving = valid.filter { $0.boundaries != startBoundaries && $0.boundaries != finalBoundaries }
        verdict.motionFrames = moving.count
        verdict.report.append("spring \(spring), origin \(Self.ms(best.origin - trigger)) ms after the change, "
            + "max error \(String(format: "%.2f", best.error)) px, \(valid.count) frames, \(moving.count) in motion")
        for frame in valid {
            let expected = boundaries(at: spring.progress(at: frame.time - best.origin)).map { String(format: "%.2f", $0) }
            verdict.report.append("  t=\(Self.ms(frame.time - best.origin)) ms \(frame.boundaries) expected [\(expected.joined(separator: ", "))]")
        }
        if moving.count < Self.minimumMotionFrames {
            verdict.failures.append("only \(moving.count) frames between the start and final layouts (at least \(Self.minimumMotionFrames))")
        }
        for frame in valid where maxError(frame, origin: best.origin) > Self.curveTolerance {
            verdict.failures.append("t=\(Self.ms(frame.time - best.origin)) ms: boundaries \(frame.boundaries) are "
                + "\(String(format: "%.2f", maxError(frame, origin: best.origin))) px from the \(spring.token) curve")
        }
        verdict.failures += monotonicFailures(valid)
        let (drops, intervals) = dropsAndIntervals(valid, origin: best.origin)
        verdict.drops = drops.count
        verdict.failures += drops
        let sorted = intervals.sorted()
        if !sorted.isEmpty {
            verdict.report.append("frame intervals in motion: p50 \(Self.ms(sorted[sorted.count / 2])) ms, "
                + "p95 \(Self.ms(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])) ms, max \(Self.ms(sorted.last ?? 0)) ms, "
                + "dropped \(drops.count)")
        }
        return verdict
    }

    private func maxError(_ frame: (time: Double, boundaries: [Int]), origin: Double) -> Double {
        let expected = boundaries(at: spring.progress(at: frame.time - origin))
        return zip(frame.boundaries, expected).map { abs(Double($0) - $1) }.max() ?? 0
    }

    private func monotonicFailures(_ valid: [(time: Double, boundaries: [Int])]) -> [String] {
        var failures: [String] = []
        for index in finalBoundaries.indices {
            let start = startBoundaries[index], end = finalBoundaries[index], travel = Double(end - start)
            guard travel != 0 else { continue }
            let direction = travel > 0 ? 1 : -1
            let allowed = spring.overshoot * abs(travel) + 1
            for (a, b) in zip(valid, valid.dropFirst()) where (b.boundaries[index] - a.boundaries[index]) * direction < 0 {
                failures.append("boundary \(index) stepped back from \(a.boundaries[index]) to \(b.boundaries[index]) px at t=\(Self.ms(b.time - trigger)) ms")
            }
            for frame in valid where Double((frame.boundaries[index] - end) * direction) > allowed
                || Double((start - frame.boundaries[index]) * direction) > 1 {
                failures.append("boundary \(index) at \(frame.boundaries[index]) px leaves \(start)...\(end) by more than the "
                    + "\(spring.token) spring's overshoot at t=\(Self.ms(frame.time - trigger)) ms")
            }
        }
        return failures
    }

    /// Between the first frame that moved and the first final one: each display refresh with no
    /// new frame although the curve moved a boundary by a whole pixel there is a dropped frame.
    private func dropsAndIntervals(_ valid: [(time: Double, boundaries: [Int])], origin: Double) -> ([String], [Double]) {
        guard let first = valid.firstIndex(where: { $0.boundaries != startBoundaries }),
              let landed = valid.firstIndex(where: { $0.boundaries == finalBoundaries }), landed > first else { return ([], []) }
        var drops: [String] = [], intervals: [Double] = []
        for index in first..<landed {
            let a = valid[index], b = valid[index + 1], gap = b.time - a.time
            intervals.append(gap)
            let missing = Int((gap / period).rounded()) - 1
            guard missing > 0 else { continue }
            let shown = boundaries(at: spring.progress(at: a.time - origin)).map { $0.rounded() }
            let due = (1...missing).contains { slot in
                boundaries(at: spring.progress(at: a.time + Double(slot) * period - origin)).map { $0.rounded() } != shown
            }
            if due {
                drops.append("dropped \(missing) frame(s) at t=\(Self.ms(a.time - origin)) ms: \(Self.ms(gap)) ms with no new frame while the curve moved")
            }
        }
        return (drops, intervals)
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
}

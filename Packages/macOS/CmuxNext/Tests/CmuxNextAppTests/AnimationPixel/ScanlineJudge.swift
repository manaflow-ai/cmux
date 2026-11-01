import Foundation

/// One thing a scanline crosses (a pane, a divider line, a gap) and where it is, in device
/// pixels along the scanline, before and after the change. The elements of a scanline tile it.
struct ScanlineElement {
    let label: String
    let before: (start: Double, end: Double)
    let after: (start: Double, end: Double)
    /// A separator (a divider line, a column gap): its run is exactly this many pixels in every frame.
    let exactLength: Int?
    /// A zone whose pixels are not one color by design (a dragged divider's lit band: a 2 pt core
    /// with a 3 pt blurred halo, DividerGlowBand): its pixels are not named, but it is bounded by
    /// the elements on each side and its width stays `exactLength`, so it moves rigidly.
    var free = false
}

/// Where every boundary between two elements must be, computed by the test: from a declared
/// spring and the start and end layouts, or from the pointer positions a drag posted. Never read
/// back from the animator (cmux-ad 2026-11-01, rule 2).
struct ScanlineOracle {
    let name: String
    /// The boundaries (device pixels) `elapsed` seconds after the motion's origin (negative: before it).
    let boundaries: (Double) -> [Double]
    /// Where the origin may be, relative to the change (input-to-display latency); one origin
    /// holds for every boundary and frame.
    let originWindow: ClosedRange<Double>
    /// How far each boundary may pass the curve's own range beyond the 1 px tolerance: a spring's
    /// declared overshoot; 0 for a drag.
    let overshoot: [Double]

    /// A spring started at rest by the change: each boundary covers the same share of its travel.
    static func spring(_ spring: DeclaredSpring, _ elements: [ScanlineElement], period: Double) -> ScanlineOracle {
        let edges = elements.dropLast().map { ($0.before.end, $0.after.end) }
        return ScanlineOracle(name: "\(spring)",
                              boundaries: { elapsed in
                                  let progress = spring.progress(at: elapsed)
                                  return edges.map { $0.0 + ($0.1 - $0.0) * progress }
                              },
                              originWindow: -2 * period...5 * period,
                              overshoot: edges.map { spring.overshoot * abs($0.1 - $0.0) })
    }
}

/// Judges every captured frame of one change along one scanline against a ``ScanlineOracle``.
/// Per frame: no pixel off the learned colors (no half-pixel blend), the elements in order with
/// no gap and no overlap, separators exactly their width, each boundary within 1 device pixel of
/// the oracle, no step against the oracle's direction and no pass beyond its range (more than a
/// spring declares), and the last frame exactly the final layout. A refresh with no new frame
/// while the oracle moved a boundary by a whole pixel is a dropped frame and fails too.
struct ScanlineJudge {
    let oracle: ScanlineOracle
    let elements: [ScanlineElement]
    /// When the change was applied (host time, seconds).
    let trigger: Double
    /// The display's refresh period.
    let period: Double
    /// Each boundary at most this far (device pixels) from the oracle. Written here, never raised.
    static let curveTolerance = 1.0
    /// A moving change shows at least this many frames between its start and end layouts.
    static let minimumMotionFrames = 8
    /// A change of structure (a pane added or closed): the scanline before the change, as labels
    /// and rounded boundaries. Frames that show it must show it exactly and come before every
    /// frame of the new structure.
    var previous: (labels: [String], boundaries: [Int])?

    typealias Shown = (time: Double, boundaries: [Int])

    struct Verdict {
        var failures: [String] = []
        var report: [String] = []
        var drops = 0
        var motionFrames = 0
    }

    var startBoundaries: [Int] { elements.dropLast().map { Int($0.before.end.rounded()) } }
    var finalBoundaries: [Int] { elements.dropLast().map { Int($0.after.end.rounded()) } }

    /// `frames` are (time, scanline) pairs in time order; `palette` names the pixels. `moves`:
    /// the change shows frames between its start and end (false: animations off, one frame).
    func judge(_ frames: [(time: Double, line: [UInt32])], palette: ScanlinePalette, moves: Bool) -> Verdict {
        var verdict = Verdict()
        let labels = elements.map(\.label)
        var valid: [Shown] = []
        for (index, frame) in frames.enumerated() where frame.time >= trigger - 3 * period {
            let runs = palette.runs(frame.line)
            let at = "frame \(index) (t=\(Self.ms(frame.time - trigger)) ms)"
            if let previous, runs.map(\.label) == previous.labels {
                let shown = Array(runs.dropLast().map(\.end))
                if !valid.isEmpty {
                    verdict.failures.append("\(at): the layout before the change shows again after the new one")
                } else if shown != previous.boundaries {
                    verdict.failures.append("\(at): the layout before the change shows at \(shown), not where it was, \(previous.boundaries)")
                }
                continue
            }
            guard let spans = match(runs) else {
                if let blend = runs.first(where: { $0.label == nil }) {
                    let colors = frame.line[blend.start..<min(blend.end, blend.start + 4)].map(ScanlinePalette.hex)
                    verdict.failures.append("\(at): \(blend.length) px at \(blend.start) match no pane, divider or gap color "
                        + "(\(colors.joined(separator: " "))): a blend, an edge off the pixel grid. Runs: \(runs)")
                } else {
                    verdict.failures.append("\(at): runs \(runs), expected \(labels): a gap, an overlap or a missing element")
                }
                continue
            }
            for (span, element) in zip(spans, elements) where element.exactLength.map({ $0 != span.end - span.start }) == true {
                verdict.failures.append("\(at): \(element.label) is \(span.end - span.start) px, not \(element.exactLength ?? 0)")
            }
            valid.append((frame.time, spans.dropLast().map(\.end)))
        }
        guard let last = valid.last, frames.last.map({ $0.time == last.time }) == true else {
            verdict.failures.append("the last captured frame is not a valid frame of the layout (\(frames.count) frames)")
            return verdict
        }
        if last.boundaries != finalBoundaries {
            verdict.failures.append("the last frame's boundaries are \(last.boundaries), the final layout's \(finalBoundaries)")
        }
        return moves ? judgeMotion(valid, verdict) : judgeInstant(valid, verdict)
    }

    /// The runs as the elements, in order: each named element is one run of its label; a free
    /// element takes every run up to the next element's label. Nil when they do not line up (a
    /// gap, an overlap, a missing element or a pixel no color names outside a free zone).
    func match(_ runs: [ScanlinePalette.Run]) -> [(start: Int, end: Int)]? {
        var spans: [(start: Int, end: Int)] = [], index = 0
        for (position, element) in elements.enumerated() {
            guard index < runs.count else { return nil }
            if element.free {
                let next = position + 1 < elements.count ? elements[position + 1].label : nil
                let start = runs[index].start
                while index < runs.count, next == nil || runs[index].label != next { index += 1 }
                spans.append((start, index < runs.count ? runs[index].start : runs[runs.count - 1].end))
            } else {
                guard runs[index].label == element.label else { return nil }
                spans.append((runs[index].start, runs[index].end))
                index += 1
            }
        }
        return index == runs.count ? spans : nil
    }

    /// Animations off: every frame after the change is the start or the final layout, and once
    /// final it stays final.
    private func judgeInstant(_ valid: [Shown], _ verdict: Verdict) -> Verdict {
        var verdict = verdict, landed = false
        for frame in valid where frame.time >= trigger {
            if frame.boundaries == finalBoundaries {
                landed = true
            } else if landed || previous != nil || frame.boundaries != startBoundaries {
                verdict.failures.append("t=\(Self.ms(frame.time - trigger)) ms: boundaries \(frame.boundaries) are neither the start "
                    + "\(startBoundaries) nor the final \(finalBoundaries) layout with animations off")
            }
        }
        if !landed { verdict.failures.append("no frame after the change shows the final layout \(finalBoundaries)") }
        return verdict
    }

    private func judgeMotion(_ valid: [Shown], _ verdict: Verdict) -> Verdict {
        var verdict = verdict
        var best = (origin: trigger, error: Double.infinity)
        var origin = trigger + oracle.originWindow.lowerBound
        while origin <= trigger + oracle.originWindow.upperBound {
            let error = valid.map { maxError($0, origin: origin) }.max() ?? .infinity
            if error < best.error { best = (origin, error) }
            origin += 0.0001
        }
        let moving = valid.filter { $0.boundaries != startBoundaries && $0.boundaries != finalBoundaries }
        verdict.motionFrames = moving.count
        verdict.report.append("oracle \(oracle.name), origin \(Self.ms(best.origin - trigger)) ms after the change, "
            + "max error \(String(format: "%.2f", best.error)) px, \(valid.count) frames, \(moving.count) in motion")
        for frame in valid {
            let expected = oracle.boundaries(frame.time - best.origin).map { String(format: "%.2f", $0) }
            verdict.report.append("  t=\(Self.ms(frame.time - best.origin)) ms \(frame.boundaries) expected [\(expected.joined(separator: ", "))]")
        }
        if moving.count < Self.minimumMotionFrames {
            verdict.failures.append("only \(moving.count) frames between the start and final layouts (at least \(Self.minimumMotionFrames))")
        }
        for frame in valid where maxError(frame, origin: best.origin) > Self.curveTolerance {
            verdict.failures.append("t=\(Self.ms(frame.time - best.origin)) ms: boundaries \(frame.boundaries) are "
                + "\(String(format: "%.2f", maxError(frame, origin: best.origin))) px from the oracle (\(oracle.name))")
        }
        verdict.failures += directionFailures(valid, origin: best.origin)
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

    private func maxError(_ frame: Shown, origin: Double) -> Double {
        zip(frame.boundaries, oracle.boundaries(frame.time - origin)).map { abs(Double($0) - $1) }.max() ?? 0
    }

    /// A boundary that steps against the oracle's direction between two frames (a backward jump),
    /// or leaves the oracle's range over the whole motion by more than 1 px plus the declared overshoot.
    private func directionFailures(_ valid: [Shown], origin: Double) -> [String] {
        var failures: [String] = []
        let expected = valid.map { oracle.boundaries($0.time - origin) }
        for index in finalBoundaries.indices {
            let values = expected.map { $0[index] }
            let low = (values.min() ?? 0) - 1 - oracle.overshoot[index], high = (values.max() ?? 0) + 1 + oracle.overshoot[index]
            for step in valid.indices.dropFirst() {
                let shown = valid[step].boundaries[index] - valid[step - 1].boundaries[index]
                let due = values[step] - values[step - 1]
                if shown != 0, abs(due) > 0.01, (Double(shown) > 0) != (due > 0) {
                    failures.append("boundary \(index) stepped back from \(valid[step - 1].boundaries[index]) to "
                        + "\(valid[step].boundaries[index]) px at t=\(Self.ms(valid[step].time - origin)) ms while the oracle moved \(String(format: "%+.2f", due)) px")
                }
            }
            for frame in valid where Double(frame.boundaries[index]) < low || Double(frame.boundaries[index]) > high {
                failures.append("boundary \(index) at \(frame.boundaries[index]) px leaves the oracle's range "
                    + "\(String(format: "%.1f", low))...\(String(format: "%.1f", high)) at t=\(Self.ms(frame.time - origin)) ms")
            }
        }
        return failures
    }

    /// Between the first frame that moved and the first final one: each display refresh with no
    /// new frame although the oracle moved a boundary by a whole pixel there is a dropped frame.
    private func dropsAndIntervals(_ valid: [Shown], origin: Double) -> ([String], [Double]) {
        guard let first = valid.firstIndex(where: { $0.boundaries != startBoundaries }),
              let landed = valid.lastIndex(where: { $0.boundaries != finalBoundaries }).map({ $0 + 1 }),
              landed > first, landed < valid.count else { return ([], []) }
        var drops: [String] = [], intervals: [Double] = []
        for index in first..<landed {
            let a = valid[index], b = valid[index + 1], gap = b.time - a.time
            intervals.append(gap)
            let missing = Int((gap / period).rounded()) - 1
            guard missing > 0 else { continue }
            let shown = oracle.boundaries(a.time - origin).map { $0.rounded() }
            let due = (1...missing).contains { slot in
                oracle.boundaries(a.time + Double(slot) * period - origin).map { $0.rounded() } != shown
            }
            if due {
                drops.append("dropped \(missing) frame(s) at t=\(Self.ms(a.time - origin)) ms: \(Self.ms(gap)) ms with no new frame while the oracle moved")
            }
        }
        return (drops, intervals)
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
}

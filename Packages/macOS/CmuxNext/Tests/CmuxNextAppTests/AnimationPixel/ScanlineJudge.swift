import Foundation

/// The axis a scanline reads: a row (pane edges along x) or a column (edges along y).
enum ScanlineAxis {
    case row
    case column
}

/// One thing a scanline crosses at one moment, in device pixels along the scanline.
struct ScanlineSpan {
    let label: String
    let start: Double
    let end: Double
    /// A separator's exact width in pixels; nil for a pane or the background.
    let exactLength: Int?
    /// The color the palette knows it by: every divider line draws the one separator color.
    var color: String { ScanlineSpan.color(of: label) }

    static func color(of label: String) -> String {
        if label.hasPrefix("divider") { return "divider" }
        if label.hasPrefix("rowedge") { return "rowedge" }
        return label
    }

    /// `spans` cut to 0..<length, in order, with "background" spans filling what lies between
    /// and around them: the whole scanline.
    static func tile(_ spans: [ScanlineSpan], length: Int) -> [ScanlineSpan] {
        let inside = spans.compactMap { span -> ScanlineSpan? in
            let start = max(span.start, 0), end = min(span.end, Double(length))
            return end > start ? ScanlineSpan(label: span.label, start: start, end: end, exactLength: span.exactLength) : nil
        }.sorted { $0.start < $1.start }
        var tiled: [ScanlineSpan] = []
        var cursor = 0.0
        for span in inside {
            if span.start > cursor + 0.01 { tiled.append(ScanlineSpan(label: "background", start: cursor, end: span.start, exactLength: nil)) }
            tiled.append(span)
            cursor = span.end
        }
        if Double(length) > cursor + 0.01 { tiled.append(ScanlineSpan(label: "background", start: cursor, end: Double(length), exactLength: nil)) }
        return tiled
    }
}

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
    var color: String { ScanlineSpan.color(of: label) }
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
        let labels = elements.map(\.color)
        var valid: [Shown] = []
        for (index, frame) in frames.enumerated() where frame.time >= trigger - 3 * period {
            let runs = palette.runs(frame.line)
            let at = "frame \(index) (t=\(Self.ms(frame.time - trigger)) ms)"
            if let previous, runs.map(\.name) == previous.labels {
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
                let pixels = frame.line[max(span.start - 1, 0)..<min(span.end + 1, frame.line.count)].map(ScanlinePalette.hex).joined(separator: " ")
                verdict.failures.append("\(at): \(element.label) is \(span.end - span.start) px, not \(element.exactLength ?? 0) (pixels \(span.start - 1)...: \(pixels))")
            }
            valid.append((time: frame.time, boundaries: spans.dropLast().map { $0.end }))
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
                let next = position + 1 < elements.count ? elements[position + 1].color : nil
                let start = runs[index].start
                while index < runs.count, next == nil || runs[index].label != next { index += 1 }
                spans.append((start: start, end: index < runs.count ? runs[index].start : runs[runs.count - 1].end))
            } else {
                guard runs[index].label == element.color else { return nil }
                spans.append((start: runs[index].start, end: runs[index].end))
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
            if error < best.error { best = (origin: origin, error: error) }
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

    /// Every display refresh from the first frame that moved to the first final one: the picture
    /// shown at that refresh is the last frame at or before it. A refresh with no new frame whose
    /// picture is more than the curve tolerance from the oracle there is a dropped frame.
    private func dropsAndIntervals(_ valid: [Shown], origin: Double) -> ([String], [Double]) {
        guard let first = valid.firstIndex(where: { $0.boundaries != startBoundaries }),
              let landed = valid.firstIndex(where: { $0.boundaries == finalBoundaries }), landed > first else { return ([], []) }
        var drops: [String] = [], intervals: [Double] = []
        for index in first..<landed { intervals.append(valid[index + 1].time - valid[index].time) }
        var slot = valid[first].time + period
        while slot < valid[landed].time - period / 2 {
            if let shown = valid.last(where: { $0.time <= slot + period / 4 }), shown.time < slot - period / 2 {
                let due = oracle.boundaries(slot - origin)
                let error = zip(shown.boundaries, due).map { abs(Double($0) - $1) }.max() ?? 0
                if error > Self.curveTolerance {
                    drops.append("dropped frame at t=\(Self.ms(slot - origin)) ms: the screen still shows \(shown.boundaries) from "
                        + "t=\(Self.ms(shown.time - origin)) ms, \(String(format: "%.2f", error)) px from the oracle")
                }
            }
            slot += period
        }
        return (drops, intervals)
    }

    /// The capture times put on the display's vsync grid, the grid's phase fitted per run from
    /// `link`, the display link's own timestamps of the window's screen in this run (the window
    /// server shows a frame only at a refresh). ScreenCaptureKit stamped the first frame after an
    /// idle stretch 2.4 ms late (green 38dc511f); on the grid that stamp cannot shift the oracle.
    ///
    /// The snap never hides a late frame: a frame shown a refresh late lands on that later
    /// refresh. A capture time more than 0.4 of a period from every refresh (3.3 ms at 120 Hz;
    /// rounding to the nearest refresh could then pick the wrong one) makes the run's timing
    /// invalid: `invalid` lists those frames and the caller fails the run with them.
    static func onVsyncGrid(_ times: [Double], link: [Double], period: Double) -> (times: [Double], maxResidual: Double, invalid: [String]) {
        let reference = link.isEmpty ? times : link
        guard !times.isEmpty, !reference.isEmpty, period > 0 else { return (times, 0, []) }
        let angles = reference.map { 2 * Double.pi * ($0 / period).truncatingRemainder(dividingBy: 1) }
        let phase = atan2(angles.map(sin).reduce(0, +), angles.map(cos).reduce(0, +)) / (2 * Double.pi)
        var snapped: [Double] = [], worst = 0.0, invalid: [String] = []
        for time in times {
            let grid = ((time / period - phase).rounded() + phase) * period
            let residual = abs(time - grid)
            worst = max(worst, residual)
            if residual > 0.4 * period {
                invalid.append("capture timing invalid: a frame stamped \(String(format: "%.2f", residual * 1000)) ms from the nearest refresh")
            }
            snapped.append(grid)
        }
        return (snapped, worst, invalid)
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }
}

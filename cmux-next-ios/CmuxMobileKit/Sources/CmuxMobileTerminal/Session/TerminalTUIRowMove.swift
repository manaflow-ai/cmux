import CoreGraphics
import Foundation

/// Leo, 2026-11-23: "we should also be able to smooth out the jaggedness of scroll that we have in
/// claude in terminal vs in regular shell terminal. latter feels smoother for some reason."
///
/// A shell's scrollback is the phone's own page: it moves under the finger a point at a time. A
/// full-screen app (Claude Code's full-screen mode, vim, less) scrolls itself: the finger's wheel goes
/// to the Mac, the app redraws its screen some rows further, and that frame lands all at once. Each
/// wheel report moved Claude Code three rows, so its transcript stood still for several frames and
/// then jumped three rows (about 50 points) in one.
///
/// This reads which rows of a presented frame are the previous frame's rows moved up or down
/// (``TerminalTUIRowMove/between(previous:current:rows:maxRows:)``), from the per-row pixel hashes
/// the screen already reads (`TerminalSurfaceView.presentedRowSignatures`), so it works for any app
/// and any input (wheel reports, cursor keys) without knowing how many rows one report moves.
public struct TerminalTUIRowMove: Equatable, Sendable {
    /// Rows the content moved: positive moved down (older rows came in at the top), negative up.
    public var rows: Int
    /// The rows of the current frame that scrolled, the rows that came in included. Rows outside
    /// it (a header, a status row, an input box) stayed where they were.
    public var band: Range<Int>

    public init(rows: Int, band: Range<Int>) {
        self.rows = rows
        self.band = band
    }

    /// Fewest rows that must have moved, and changed, for a frame to count as scrolled: a spinner
    /// row redrawn in place, or two blank rows that happen to line up, are not a scroll.
    public static let minimumMovedRows = 3

    /// How `current` (one hash per cell row) moved from `previous`, over the screen's `rows`: the
    /// shift of at most `maxRows` rows whose longest run of rows equal to the previous frame's,
    /// shifted, holds the most rows that differ from the same row unshifted. Nil when nothing
    /// moved (a redraw in place, a new screen, the same frame).
    public static func between(previous: [UInt64], current: [UInt64], rows: Range<Int>, maxRows: Int = 12) -> TerminalTUIRowMove? {
        let rows = rows.clamped(to: 0..<min(previous.count, current.count))
        guard rows.count > minimumMovedRows, maxRows > 0 else { return nil }
        var best: (score: Int, shift: Int, run: Range<Int>)?
        for magnitude in 1...min(maxRows, rows.count - 1) {
            for shift in [magnitude, -magnitude] {
                // Rows of `current` whose source row `i - shift` is on the screen too.
                let lower = max(rows.lowerBound, rows.lowerBound + shift), upper = min(rows.upperBound, rows.upperBound + shift)
                guard lower < upper else { continue }
                var start = lower, score = 0
                for i in lower...upper {
                    let equal = i < upper && current[i] == previous[i - shift] && current[i] != TerminalPresentMatch.unread
                    if equal {
                        if current[i] != previous[i] { score += 1 }
                        continue
                    }
                    if score >= minimumMovedRows, score > best?.score ?? 0 {
                        best = (score, shift, start..<i)
                    }
                    start = i + 1
                    score = 0
                }
            }
        }
        guard let best else { return nil }
        let run = best.run
        // The rows that came in: above the run when the content moved down, below it when up.
        let band = best.shift > 0
            ? max(rows.lowerBound, run.lowerBound - best.shift)..<run.upperBound
            : run.lowerBound..<min(rows.upperBound, run.upperBound - best.shift)
        return TerminalTUIRowMove(rows: best.shift, band: band)
    }
}

/// The glide that turns a full-screen app's row jumps into motion: when a frame shows the content
/// `n` rows further, the band is first drawn where the last frame's rows were (``offset`` is
/// `-n` rows), then slides to its place at a steady speed, so it arrives about when the app's next
/// jump is due (``interval``, learned from the jumps so far). With jumps every few frames the
/// rows move a few points each frame, as a shell's scrollback does, instead of standing still and
/// then jumping.
public struct TerminalTUIRowGlide: Equatable, Sendable {
    /// Points the current frame's band is drawn from its place: positive is down.
    public private(set) var offset: CGFloat = 0
    /// Points per second the band slides toward its place.
    private var speed: CGFloat = 0
    /// When the last jump came (seconds, the media clock).
    private var lastJump: CFTimeInterval?
    /// The time between the app's jumps, as last measured (seconds).
    public private(set) var interval: CFTimeInterval = TerminalTUIRowGlide.startInterval

    /// Before two jumps are seen: about two frames at 60 Hz plus a round trip on Wi-Fi.
    public static let startInterval: CFTimeInterval = 0.05
    /// The glide never takes less (a jump every frame needs none) or more (a slow redraw would lag).
    public static let shortestInterval: CFTimeInterval = 1.0 / 120
    public static let longestInterval: CFTimeInterval = 0.12
    /// Jumps further apart than this start a new burst: the gap is not the app's cadence.
    public static let burstGap: CFTimeInterval = 0.3
    /// The glide ends a little before the next jump is due, so a late jump never finds the band
    /// still sliding (the next jump would cut that slide short).
    public static let lead: CGFloat = 0.85

    public init() {}

    public var isGliding: Bool { offset != 0 }

    /// A frame presented at `time` shows the content `rows` rows further (``TerminalTUIRowMove``):
    /// the band starts where the last frame's rows were. What remained of an earlier glide is let
    /// go (the band shows the new frame now), so the band never trails more than one jump.
    public mutating func jumped(rows: Int, rowHeight: CGFloat, at time: CFTimeInterval) {
        guard rows != 0, rowHeight > 0 else { return }
        if let lastJump, time - lastJump < Self.burstGap {
            let measured = min(Self.longestInterval, max(Self.shortestInterval, time - lastJump))
            interval = 0.5 * interval + 0.5 * measured
        }
        lastJump = time
        offset = -CGFloat(rows) * rowHeight
        speed = abs(offset) / (CGFloat(interval) * Self.lead)
    }

    /// One display frame `dt` seconds after the last: the band slides toward its place. Returns
    /// whether it is still sliding.
    @discardableResult
    public mutating func step(dt: CFTimeInterval) -> Bool {
        guard offset != 0 else { return false }
        let move = speed * CGFloat(max(0, min(0.05, dt)))
        offset = abs(offset) <= move ? 0 : offset - move * (offset > 0 ? 1 : -1)
        return offset != 0
    }

    /// The app left its screen, or the page went away: the band is drawn in place at once.
    public mutating func stop() {
        offset = 0
        speed = 0
        lastJump = nil
        interval = Self.startInterval
    }
}

/// How smoothly content moved over one pan, from where it was drawn each display frame (points):
/// the bench's measure of jaggedness, the same for a shell's page and a full-screen app.
public struct TerminalScrollSmoothness: Equatable, Sendable {
    /// Frames from the first move to the last.
    public var frames: Int
    /// Per-frame moves (points), median and 95th percentile, and the largest.
    public var stepP50: CGFloat
    public var stepP95: CGFloat
    public var stepMax: CGFloat
    /// Share of those frames (0...1) in which the content did not move at all.
    public var stillShare: Double

    /// A frame whose content moved less than this (points) stood still.
    public static let stillThreshold: CGFloat = 0.25

    /// `positions`: where the content was drawn each frame, in frame order. Nil when it never moved.
    public init?(positions: [CGFloat]) {
        self.init(steps: zip(positions.dropFirst(), positions).map { abs($0 - $1) })
    }

    /// `steps`: how far the content moved each frame (points). Nil when it never moved.
    public init?(steps: [CGFloat]) {
        guard let first = steps.firstIndex(where: { $0 >= Self.stillThreshold }),
              let last = steps.lastIndex(where: { $0 >= Self.stillThreshold }) else { return nil }
        let moving = Array(steps[first...last])
        let sorted = moving.sorted()
        func quantile(_ q: Double) -> CGFloat { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        frames = moving.count
        stepP50 = quantile(0.5)
        stepP95 = quantile(0.95)
        stepMax = sorted.last ?? 0
        stillShare = Double(moving.filter { $0 < Self.stillThreshold }.count) / Double(moving.count)
    }

    /// ` motionFrames=N stepP50Pct=N stepP95Pct=N stepMaxPct=N stillPct=N`: steps as a percent of
    /// a row of `rowHeight` points (the bench's label reads whole numbers).
    public func note(rowHeight: CGFloat) -> String {
        func pct(_ points: CGFloat) -> Int { rowHeight > 0 ? Int((points / rowHeight * 100).rounded()) : 0 }
        return " motionFrames=\(frames) stepP50Pct=\(pct(stepP50)) stepP95Pct=\(pct(stepP95)) stepMaxPct=\(pct(stepMax))"
            + " stillPct=\(Int((stillShare * 100).rounded()))"
    }
}

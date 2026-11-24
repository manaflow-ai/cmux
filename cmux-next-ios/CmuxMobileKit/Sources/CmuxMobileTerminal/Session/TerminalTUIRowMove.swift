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
/// `-n` rows), then slides to its place.
///
/// Leo, 2026-11-24: "for scrolling on iphone, honestly, theres a world in which we dont bother
/// scrolling 'line by line' so to speak. we can still highlight text and whatnot, but... we can
/// just treat the scroll like any pedestrian scroll." So while the finger (or its fling) is
/// scrolling, the band slides at the finger's own speed (``wheel(dy:at:)``: the wheel's points
/// times the rows the app moves per wheel point, learned from its jumps), like a plain scroll
/// view: the rows move every frame, as far as the finger moved, never a row at a time. Once the
/// finger stops, what is left eases into place (``settleTime``). With no wheel seen (the app
/// scrolled by itself, a cursor key) it slides at a steady speed that arrives about when the
/// app's next jump is due (``interval``).
public struct TerminalTUIRowGlide: Equatable, Sendable {
    /// Points the current frame's band is drawn from its place: positive is down.
    public private(set) var offset: CGFloat = 0
    /// Points per second the band slides toward its place (no finger: the app's cadence).
    private var speed: CGFloat = 0
    /// When the last jump came (seconds, the media clock).
    private var lastJump: CFTimeInterval?
    /// The time between the app's jumps, as last measured (seconds).
    public private(set) var interval: CFTimeInterval = TerminalTUIRowGlide.startInterval

    /// The finger's speed in content points per second (its wheel times ``rowsPerWheelPoint``).
    public private(set) var fingerSpeed: CGFloat = 0
    /// Content points the app moves per wheel point (Claude Code moves three rows per wheel
    /// report), learned from each jump over the wheel sent since the one before.
    public private(set) var rowsPerWheelPoint: CGFloat = 1
    private var sentSinceJump: CGFloat = 0
    private var lastWheel: CFTimeInterval?
    /// Seconds of display frames since the last wheel (``step(dt:)``).
    private var idle: CFTimeInterval = 0
    /// A wheel was seen in this burst: the finger leads the glide.
    private var fingerLeads = false

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
    /// No wheel for this long (seconds): the finger stopped, and the rest eases into place.
    public static let fingerIdle: CFTimeInterval = 0.08
    /// The ease's time constant once the finger stopped (seconds), and its slowest speed
    /// (points per second) so it always ends.
    public static let settleTime: CFTimeInterval = 0.05
    public static let settleFloor: CGFloat = 60
    /// The learned ratio stays within these (a stray frame match cannot make it absurd).
    public static let ratioRange: ClosedRange<CGFloat> = 0.25...8

    public init() {}

    public var isGliding: Bool { offset != 0 }

    /// A wheel report of `dy` points went to the app at `time` (seconds, the media clock):
    /// the finger's speed, in the content points the app will move.
    public mutating func wheel(dy: CGFloat, at time: CFTimeInterval) {
        guard dy != 0 else { return }
        sentSinceJump += abs(dy)
        defer {
            lastWheel = time
            idle = 0
            fingerLeads = true
        }
        guard let lastWheel, time - lastWheel < Self.burstGap else {
            fingerSpeed = 0
            return
        }
        let measured = abs(dy) * rowsPerWheelPoint / CGFloat(max(time - lastWheel, Self.shortestInterval / 2))
        fingerSpeed = fingerSpeed == 0 ? measured : 0.5 * fingerSpeed + 0.5 * measured
    }

    /// A frame presented at `time` shows the content `rows` rows further (``TerminalTUIRowMove``):
    /// the band starts where the last frame's rows were, plus what the glide had not yet slid
    /// (up to one more row, the edge rows the smoother keeps for the gap).
    public mutating func jumped(rows: Int, rowHeight: CGFloat, at time: CFTimeInterval) {
        guard rows != 0, rowHeight > 0 else { return }
        if let lastJump, time - lastJump < Self.burstGap {
            let measured = min(Self.longestInterval, max(Self.shortestInterval, time - lastJump))
            interval = 0.5 * interval + 0.5 * measured
        }
        lastJump = time
        // The display clock stops at rest: a jump that comes after the finger stopped eases.
        if let lastWheel { idle = max(idle, time - lastWheel) }
        let moved = CGFloat(rows) * rowHeight
        if sentSinceJump > 0 {
            let ratio = abs(moved) / sentSinceJump
            let clamped = min(Self.ratioRange.upperBound, max(Self.ratioRange.lowerBound, ratio))
            rowsPerWheelPoint = 0.5 * rowsPerWheelPoint + 0.5 * clamped
            sentSinceJump = 0
        }
        let carried = (offset != 0 && (offset < 0) == (moved > 0)) ? offset : 0
        let limit = abs(moved) + rowHeight
        offset = max(-limit, min(limit, carried - moved))
        speed = abs(offset) / (CGFloat(interval) * Self.lead)
    }

    /// One display frame `dt` seconds after the last: the band slides toward its place. Returns
    /// whether it is still sliding.
    @discardableResult
    public mutating func step(dt: CFTimeInterval) -> Bool {
        let dt = max(0, min(0.05, dt))
        idle += dt
        guard offset != 0 else { return false }
        let move: CGFloat
        if fingerLeads, idle < Self.fingerIdle, fingerSpeed > 0 {
            move = fingerSpeed * CGFloat(dt)
        } else if fingerLeads {
            move = max(abs(offset) * CGFloat(1 - exp(-dt / Self.settleTime)), Self.settleFloor * CGFloat(dt))
        } else {
            move = speed * CGFloat(dt)
        }
        offset = abs(offset) <= move ? 0 : offset - move * (offset > 0 ? 1 : -1)
        return offset != 0
    }

    /// The app left its screen, or the page went away: the band is drawn in place at once.
    public mutating func stop() {
        offset = 0
        speed = 0
        lastJump = nil
        interval = Self.startInterval
        fingerSpeed = 0
        sentSinceJump = 0
        lastWheel = nil
        idle = 0
        fingerLeads = false
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

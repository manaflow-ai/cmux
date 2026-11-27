/// Which viewport a presented Ghostty frame shows (the rows' top row), read
/// from its pixels: the frame's row signatures are matched against the
/// previous frame's for candidate shifts. Ghostty renders on its own thread,
/// its viewport reports and frames reach the main thread in either order, and
/// a frame rendered before a request or a report can be presented after it.
/// Portable rule of `TerminalViewController.surfacePresented` (termqa D7).
public struct TerminalPresentMatch: Equatable, Sendable {
    /// The top row of the frame on screen until now.
    public var presentedTop: Int
    /// Ghostty's last viewport report.
    public var reportedTop: Int
    /// The last viewport asked for, and the ones before it.
    public var requestedTop: Int
    public var recentRequests: [Int]
    /// The active area's top (the bottom of the scrollback).
    public var activeTop: Int
    /// The last request was sent after the last report (`TerminalViewportTop`):
    /// Ghostty's viewport is the request, and the report is older.
    public var requestIsNewer: Bool

    public init(presentedTop: Int, reportedTop: Int, requestedTop: Int, recentRequests: [Int], activeTop: Int,
                requestIsNewer: Bool = false) {
        self.presentedTop = presentedTop
        self.reportedTop = reportedTop
        self.requestedTop = requestedTop
        self.recentRequests = recentRequests
        self.activeTop = activeTop
        self.requestIsNewer = requestIsNewer
    }

    /// Shifts from `presentedTop` to every viewport a frame in flight may
    /// show, in order of likelihood (ties go to the earlier one).
    public var candidateShifts: [Int] {
        var shifts: [Int] = []
        for top in [reportedTop, requestedTop, presentedTop] + recentRequests.reversed() + [activeTop]
            where !shifts.contains(top - presentedTop) {
            shifts.append(top - presentedTop)
        }
        // A frame Ghostty rendered a row or two before (or after) the one on
        // screen while it followed the output on its own: no request names
        // it (termqa D7). Last, so they win only on a strictly better match.
        for shift in [-1, 1, -2, 2] where !shifts.contains(shift) { shifts.append(shift) }
        return shifts
    }

    /// The frame's top row: the best matching candidate (at least 90 % of the
    /// non-blank rows equal), else the newer of the last request and report.
    public func top(previous: [UInt64], current: [UInt64]) -> Int {
        match(previous: previous, current: current).top
    }

    /// The frame's top row and whether a candidate matched (false: the last
    /// report, a fallback).
    public func match(previous: [UInt64], current: [UInt64]) -> (top: Int, matched: Bool) {
        var best: (shift: Int, score: Double)?
        let blank = Self.mostCommon(current)
        // No frame shows a viewport past the active area's top (V6-2: after
        // a prune while following, the frame on screen still had its top in
        // the old numbering, and a +1 match placed the next one past the
        // document's end).
        for shift in candidateShifts where (0...max(0, activeTop)).contains(presentedTop + shift) {
            let score = Self.score(previous, current, shift: shift, blank: blank)
            if score > (best?.score ?? -1) + 0.02 { best = (shift, score) }
        }
        if let best, best.score >= 0.9 { return (presentedTop + best.shift, true) }
        // No candidate matched (a jump: the frame shares no rows with the
        // one on screen). Ghostty's viewport is the request when it is newer
        // than the report (termqa N1: a restore's first frame came before
        // the report for its request, was placed at the report's end of
        // the replay, and every later frame matched it there).
        if requestIsNewer, requestedTop >= 0 { return (min(requestedTop, max(0, activeTop)), false) }
        return (reportedTop, false)
    }

    /// The viewport a read frame confirmed, when frames after it need no
    /// pixel read: it matched, it is the viewport asked for and reported, and
    /// it is in the scrollback (Ghostty moves the viewport on its own only in
    /// the active area, where it follows the output).
    public func confirmed(_ result: (top: Int, matched: Bool), epoch: Int) -> TerminalSteadyViewport? {
        guard result.matched, result.top == reportedTop, result.top == requestedTop, result.top < activeTop else { return nil }
        return TerminalSteadyViewport(top: result.top, epoch: epoch)
    }

    /// The new frame's top row without reading its pixels, when it is known:
    /// the confirmed viewport, while nothing moved it since (the same request
    /// and report, the same surface epoch, still in the scrollback). Frames
    /// reach the main thread in render order, so none older than the
    /// confirmed one comes after it.
    public func knownTop(steady: TerminalSteadyViewport?, epoch: Int) -> Int? {
        guard let steady, steady.epoch == epoch, steady.top == presentedTop, reportedTop == steady.top,
              requestedTop == steady.top, steady.top < activeTop else { return nil }
        return steady.top
    }

    /// Fraction of the new frame's non-blank rows equal to the previous
    /// frame's rows `shift` further down (1 = the same picture moved by `shift`).
    /// Rows can be `unread` (outside the read band): they are never compared.
    public static func score(_ previous: [UInt64], _ current: [UInt64], shift: Int) -> Double {
        score(previous, current, shift: shift, blank: mostCommon(current))
    }

    static func score(_ previous: [UInt64], _ current: [UInt64], shift: Int, blank: UInt64) -> Double {
        var compared = 0, equal = 0
        for index in current.indices {
            let other = index + shift
            guard other >= 0, other < previous.count else { continue }
            let value = current[index]
            guard value != blank, value != unread, previous[other] != unread else { continue }
            compared += 1
            if previous[other] == value { equal += 1 }
        }
        return compared < 4 ? -1 : Double(equal) / Double(compared)
    }

    /// A row outside the read band (`TerminalSurfaceView.presentedRowSignatures`).
    public static let unread: UInt64 = 0

    /// The surface rows a present reads while following: the rows on screen
    /// and `margin` rows on each side (a frame shifted by new output or a
    /// stale frame a few rows off still overlaps it), clamped to the surface.
    public static func readBand(visible: Range<Int>, rowCount: Int, margin: Int) -> Range<Int> {
        let lower = max(0, min(rowCount, visible.lowerBound - margin))
        let upper = max(lower, min(rowCount, visible.upperBound + margin))
        return lower..<upper
    }

    private static func mostCommon(_ values: [UInt64]) -> UInt64 {
        // The blank row: the most common read value (unread rows excluded).
        // Sorted runs, no dictionary: this runs for every presented frame.
        var sorted = values.filter { $0 != unread }
        guard !sorted.isEmpty else { return unread }
        sorted.sort()
        var best = sorted[0], bestCount = 0, run = 0
        for index in sorted.indices {
            run = index > 0 && sorted[index] == sorted[index - 1] ? run + 1 : 1
            if run > bestCount { bestCount = run; best = sorted[index] }
        }
        return best
    }
}

/// A viewport a read frame confirmed (`TerminalPresentMatch.confirmed`), and
/// the surface's viewport epoch then: anything that can move Ghostty's
/// viewport (a scroll request, a resize, a font change) bumps the epoch.
public struct TerminalSteadyViewport: Equatable, Sendable {
    public var top: Int
    public var epoch: Int

    public init(top: Int, epoch: Int) {
        self.top = top
        self.epoch = epoch
    }
}

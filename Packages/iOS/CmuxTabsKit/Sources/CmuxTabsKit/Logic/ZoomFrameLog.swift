import Foundation

/// Frame times of one tap-started zoom, from the tap to the frame it settles
/// in: the first interval is the tap to the first frame the zoom draws, the
/// rest are display frame to display frame (a frame the main thread missed
/// shows as a longer interval).
struct ZoomFrameLog: Equatable, Sendable {
    struct Summary: Equatable, Sendable, Codable {
        var toOverview: Bool
        var frames: Int
        var durationMs: Double
        var firstFrameMs: Double
        var worstMs: Double
        /// Intervals longer than a 120 Hz frame (8.3 ms) and a 60 Hz frame
        /// (16.7 ms), each with 0.5 ms of vsync jitter allowed.
        var over8ms: Int
        var over16ms: Int
        var maxFPS: Int
        /// What the screen drew of the accessory row during the zoom.
        var row: AccessoryTrace.Summary? = nil
        /// When the zoom started and ended (CACurrentMediaTime, ms), to line
        /// it up with the main-thread tracer's hitches.
        var startMs: Double = 0
        var endMs: Double = 0
        /// The views re-run while the zoom moved (`ZoomWork`): the screen,
        /// the grid and its cards. Counted, not timed, so the same on any
        /// host: a zoom whose grid or cards re-run every frame does work in
        /// proportion to the tabs on every frame.
        var work: ZoomWork.Counts? = nil
    }

    static let jitter = 0.0005

    private(set) var intervals: [Double] = []
    private(set) var toOverview = false
    private var last: Double?

    var isRunning: Bool { last != nil }

    private var start: Double = 0

    mutating func begin(at time: Double, toOverview: Bool) {
        intervals = []
        last = time
        start = time
        self.toOverview = toOverview
    }

    mutating func frame(at time: Double) {
        guard let last else { return }
        intervals.append(max(0, time - last))
        self.last = time
    }

    /// Ends the log and returns its summary (nil when none was running).
    mutating func end(maxFPS: Int) -> Summary? {
        guard let end = last else { return nil }
        last = nil
        let ms = intervals.map { $0 * 1000 }
        return Summary(toOverview: toOverview, frames: ms.count, durationMs: ms.reduce(0, +), firstFrameMs: ms.first ?? 0,
                       worstMs: ms.max() ?? 0,
                       over8ms: intervals.filter { $0 > 1.0 / 120 + Self.jitter }.count,
                       over16ms: intervals.filter { $0 > 1.0 / 60 + Self.jitter }.count,
                       maxFPS: maxFPS, startMs: start * 1000, endMs: end * 1000)
    }
}

/// How many times the tab screen's views re-ran while a zoom moved.
struct ZoomWork: Equatable, Sendable {
    struct Counts: Equatable, Sendable, Codable {
        /// The tab screen (one per frame is expected: it places the zooming page).
        var screen = 0
        /// The grid's body.
        var grid = 0
        /// Grid card bodies, all cards together.
        var cards = 0
    }

    enum View: Sendable { case screen, grid, card }

    private(set) var counts = Counts()

    mutating func note(_ view: View) {
        switch view {
        case .screen: counts.screen += 1
        case .grid: counts.grid += 1
        case .card: counts.cards += 1
        }
    }

    mutating func reset() { counts = Counts() }
}

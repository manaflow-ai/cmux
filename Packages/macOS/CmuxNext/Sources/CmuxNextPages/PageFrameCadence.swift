#if DEBUG
public import CmuxNextSettings

/// How often a page rendered a frame over one probe window (`debug.page {action: frames}`).
///
/// Built from the page's own `requestAnimationFrame` intervals, so it reads the cadence of the
/// page's main-thread rendering (scroll handlers, rAF, JS-driven fades), the work WebKit's
/// near-60 fps preference halves on a 120 Hz display (perf-lead row 23). A long frame is one
/// interval longer than 1.5 display refreshes: one or more refreshes the page did not render.
///
/// ```swift
/// let cadence = PageFrameCadence(intervalsMs: [8.3, 8.4, 16.7], windowMs: 1000, displayFPS: 120)
/// cadence.longFrames // 1
/// ```
public nonisolated struct PageFrameCadence: Sendable, Equatable {
    /// The intervals between consecutive frames, in milliseconds, in the order the page drew them.
    public let intervalsMs: [Double]
    /// The probe window in milliseconds.
    public let windowMs: Double
    /// The refresh rate of the display the page is on, nil when the page has no window.
    public let displayFPS: Double?

    /// Makes the summary of one probe window.
    ///
    /// - Parameter intervalsMs: The page's rAF intervals in milliseconds.
    /// - Parameter windowMs: How long the probe watched, in milliseconds.
    /// - Parameter displayFPS: The display's refresh rate (`NSScreen.maximumFramesPerSecond`), nil
    ///   without a window; then no frame counts as long.
    public init(intervalsMs: [Double], windowMs: Double, displayFPS: Double?) {
        self.intervalsMs = intervalsMs
        self.windowMs = windowMs
        self.displayFPS = displayFPS
    }

    /// The interval at `fraction` (0...1) of the sorted intervals (nearest rank), nil without frames.
    public func percentileMs(_ fraction: Double) -> Double? {
        guard !intervalsMs.isEmpty else { return nil }
        let sorted = intervalsMs.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Intervals longer than 1.5 display refreshes (each one at least one refresh not rendered).
    public var longFrames: Int {
        guard let displayFPS, displayFPS > 0 else { return 0 }
        let limit = 1.5 * 1000 / displayFPS
        return intervalsMs.filter { $0 > limit }.count
    }

    /// Frames rendered per second over the intervals measured, nil without frames.
    public var observedFPS: Double? {
        let total = intervalsMs.reduce(0, +)
        return total > 0 ? Double(intervalsMs.count) * 1000 / total : nil
    }

    /// The summary as `debug.page` returns it: `frames`, `window_ms`, `observed_fps`, `p50_ms`,
    /// `p95_ms`, `max_ms`, `long_frames`, `display_fps` and the raw `intervals_ms` (a bench pools
    /// several windows for its own percentiles).
    public var json: JSONValue {
        let number: (Double?) -> JSONValue = { $0.map { .number(($0 * 100).rounded() / 100) } ?? .null }
        return [
            "frames": .number(Double(intervalsMs.count)),
            "window_ms": .number(windowMs),
            "observed_fps": number(observedFPS),
            "p50_ms": number(percentileMs(0.5)),
            "p95_ms": number(percentileMs(0.95)),
            "max_ms": number(intervalsMs.max()),
            "long_frames": .number(Double(longFrames)),
            "display_fps": number(displayFPS),
            "intervals_ms": .array(intervalsMs.map { number($0) }),
        ]
    }
}
#endif

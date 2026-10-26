/// Scroll jank as Chrome counts it: a port of cc's `ScrollJankDroppedFrameTracker`
/// (cc/metrics/scroll_jank_dropped_frame_tracker.cc).
///
/// Each presented scroll frame is compared with the frame presented before it. A frame is janky
/// (delayed) when the gap between the two presentations is more than 1.5 vsync intervals AND the
/// frame's oldest input was generated before the previous presentation: the input was there and
/// a frame that could have shown it was missed. Its missed vsyncs are Chrome's
/// `(gap + vsync / 2) / vsync - 1` in integer time division (so a 2.6-vsync gap misses 2).
///
/// It reports Chrome's histograms:
/// - `Event.ScrollJank.DelayedFramesPercentage.FixedWindow`, `.MissedVsyncsSum.FixedWindow` and
///   `.MissedVsyncsMax.FixedWindow`, once per ``fixedWindowFrames`` (64) presented frames.
/// - The same three `.PerScroll`, once per scroll, when the next scroll starts (Chrome emits a
///   scroll's histograms at the next `OnScrollStarted`).
///
/// A scroll's first frame has no frame before it in the scroll: it only sets the previous
/// presentation and is not counted. Frames Chrome skips are skipped too: the last input older than
/// the first, a presentation not after the last input, and a presentation not after the previous
/// one (out of order).
///
/// A value type with no lock: the ``InputLatencyLedger`` that owns it folds batches off main.
public struct ScrollJankTracker: Sendable, Equatable {
    /// Presented frames per fixed window (Chrome `kHistogramEmitFrequency`).
    public static let fixedWindowFrames = 64

    /// One window's or one scroll's counts (Chrome `JankData`).
    public struct JankData: Sendable, Equatable {
        /// Frames counted.
        public var presentedFrames = 0
        /// Janky frames.
        public var delayedFrames = 0
        /// Vsyncs the janky frames missed in total.
        public var missedVsyncsSum = 0
        /// The most vsyncs one janky frame missed.
        public var missedVsyncsMax = 0

        public init() {}

        /// Janky frames as a whole percentage of the frames counted (Chrome's integer division).
        public var delayedFramesPercentage: Int {
            presentedFrames > 0 ? 100 * delayedFrames / presentedFrames : 0
        }

        /// Counts one presented frame that missed `missed` vsyncs when `janky`.
        mutating func count(janky: Bool, missed: Int) {
            presentedFrames += 1
            guard janky else { return }
            delayedFrames += 1
            missedVsyncsSum += missed
            missedVsyncsMax = max(missedVsyncsMax, missed)
        }
    }

    /// The emitted values, per Chrome histogram name.
    public private(set) var histograms = ScrollJankHistograms()
    /// Frames counted since the tracker was made.
    public private(set) var presentedFrames: UInt64 = 0
    /// Janky frames since the tracker was made.
    public private(set) var delayedFrames: UInt64 = 0
    /// Frames skipped (first of a scroll, out of order or with inconsistent timestamps).
    public private(set) var skippedFrames: UInt64 = 0

    private var fixedWindow = JankData()
    private var perScroll: JankData?
    /// The previous presentation in the current scroll, 0 before its first frame.
    private var previousPresented: UInt64 = 0

    public init() {}

    /// A scroll began (Chrome `OnScrollStarted`): the previous scroll's histograms are emitted if
    /// it presented a frame. A second call before the new scroll presents a frame changes nothing,
    /// so both a scroll's begin and its first update may call it.
    public mutating func scrollStarted() {
        if let scroll = perScroll {
            guard scroll.presentedFrames > 0 || previousPresented != 0 else { return }
            if scroll.presentedFrames > 0 {
                histograms.record(.delayedFramesPercentagePerScroll, scroll.delayedFramesPercentage)
                histograms.record(.missedVsyncsSumPerScroll, scroll.missedVsyncsSum)
                histograms.record(.missedVsyncsMaxPerScroll, scroll.missedVsyncsMax)
            }
        }
        perScroll = JankData()
        previousPresented = 0
    }

    /// One presented scroll frame (Chrome `ReportLatestPresentationData`).
    ///
    /// - Parameters:
    ///   - firstGenerated: The OS time of the oldest input the frame shows.
    ///   - lastGenerated: The OS time of the newest input the frame shows.
    ///   - presented: When the frame reached the display.
    ///   - vsyncNanos: The display's refresh interval.
    public mutating func framePresented(firstGenerated: UInt64, lastGenerated: UInt64, presented: UInt64, vsyncNanos: UInt64) {
        guard vsyncNanos > 0, firstGenerated > 0, lastGenerated >= firstGenerated, presented > lastGenerated else {
            skippedFrames &+= 1
            return
        }
        guard previousPresented != 0 else {
            previousPresented = presented
            skippedFrames &+= 1
            return
        }
        guard presented > previousPresented else {
            skippedFrames &+= 1
            return
        }
        let gap = presented - previousPresented
        let janky = gap > vsyncNanos + vsyncNanos / 2 && firstGenerated < previousPresented
        let missed = janky ? Int(clamping: (gap + vsyncNanos / 2) / vsyncNanos - 1) : 0
        fixedWindow.count(janky: janky, missed: missed)
        var scroll = perScroll ?? JankData()
        scroll.count(janky: janky, missed: missed)
        perScroll = scroll
        presentedFrames &+= 1
        if janky { delayedFrames &+= 1 }
        previousPresented = presented
        if fixedWindow.presentedFrames == Self.fixedWindowFrames {
            histograms.record(.delayedFramesPercentageFixedWindow, fixedWindow.delayedFramesPercentage)
            histograms.record(.missedVsyncsSumFixedWindow, fixedWindow.missedVsyncsSum)
            histograms.record(.missedVsyncsMaxFixedWindow, fixedWindow.missedVsyncsMax)
            fixedWindow = JankData()
        }
    }

    /// Moves the counts out (the emitted histograms and the frame counters) and returns them as a
    /// tracker of counts only. The fixed window not yet full, the scroll in progress and its
    /// previous presentation stay, as cc's tracker keeps its state across UMA uploads.
    public mutating func takeCounts() -> ScrollJankTracker {
        var counts = ScrollJankTracker()
        counts.histograms = histograms
        counts.presentedFrames = presentedFrames
        counts.delayedFrames = delayedFrames
        counts.skippedFrames = skippedFrames
        histograms = ScrollJankHistograms()
        presentedFrames = 0
        delayedFrames = 0
        skippedFrames = 0
        return counts
    }

    /// Adds the counts of `other` (emitted histograms and frame counters), not its state.
    public mutating func addCounts(_ other: ScrollJankTracker) {
        histograms.add(other.histograms)
        presentedFrames &+= other.presentedFrames
        delayedFrames &+= other.delayedFrames
        skippedFrames &+= other.skippedFrames
    }

    /// The counts of the window not yet full.
    public var currentWindow: JankData { fixedWindow }
    /// The counts of the scroll in progress, nil before the first scroll.
    public var currentScroll: JankData? { perScroll }
}

/// The values ``ScrollJankTracker`` emitted, one exact distribution per Chrome histogram.
public struct ScrollJankHistograms: Sendable, Equatable {
    /// Chrome's histogram names.
    public enum Name: String, Sendable, CaseIterable, Codable {
        case delayedFramesPercentageFixedWindow = "Event.ScrollJank.DelayedFramesPercentage.FixedWindow"
        case missedVsyncsSumFixedWindow = "Event.ScrollJank.MissedVsyncsSum.FixedWindow"
        case missedVsyncsMaxFixedWindow = "Event.ScrollJank.MissedVsyncsMax.FixedWindow"
        case delayedFramesPercentagePerScroll = "Event.ScrollJank.DelayedFramesPercentage.PerScroll"
        case missedVsyncsSumPerScroll = "Event.ScrollJank.MissedVsyncsSum.PerScroll"
        case missedVsyncsMaxPerScroll = "Event.ScrollJank.MissedVsyncsMax.PerScroll"
    }

    /// Per histogram, how many times each value was emitted.
    public private(set) var values: [Name: [Int: UInt64]] = [:]

    public init() {}

    /// Counts one emitted `value` of `name`.
    public mutating func record(_ name: Name, _ value: Int) {
        values[name, default: [:]][value, default: 0] &+= 1
    }

    /// Adds every value `other` emitted.
    public mutating func add(_ other: ScrollJankHistograms) {
        for (name, counts) in other.values {
            for (value, count) in counts { values[name, default: [:]][value, default: 0] &+= count }
        }
    }

    /// How many values `name` emitted.
    public func count(_ name: Name) -> UInt64 {
        values[name]?.values.reduce(0, &+) ?? 0
    }

    /// The histograms as report fields, keyed by Chrome's names; only emitted ones.
    public var snapshot: [String: ScrollJankHistogramSnapshot] {
        var result: [String: ScrollJankHistogramSnapshot] = [:]
        for (name, counts) in values {
            let samples = counts.sorted { $0.key < $1.key }.map { ScrollJankHistogramSnapshot.Sample(value: $0.key, count: $0.value) }
            result[name.rawValue] = ScrollJankHistogramSnapshot(samples: samples)
        }
        return result
    }
}

/// One scroll jank histogram as report fields: `samples`, each `value` with its `count`, by value.
public struct ScrollJankHistogramSnapshot: Sendable, Equatable, Codable {
    public struct Sample: Sendable, Equatable, Codable {
        public var value: Int
        public var count: UInt64

        public init(value: Int, count: UInt64) {
            self.value = value
            self.count = count
        }
    }

    public var samples: [Sample]

    public init(samples: [Sample]) {
        self.samples = samples
    }
}

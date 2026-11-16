import Foundation

/// The last `capacity` samples of one measure (milliseconds), oldest overwritten first: a
/// fixed-size window, so a session streaming for days holds the same few hundred bytes.
/// Read by `mac_screen.state` (`cmux app mac-screens`) as p50, p95 and max.
nonisolated struct MacScreenRollingSamples: Equatable, Sendable {
    nonisolated struct Summary: Equatable, Sendable {
        var count: Int
        var p50: Double
        var p95: Double
        var max: Double
    }

    let capacity: Int
    private var values: [Double] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = Swift.max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    var count: Int { values.count }

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        if values.count < capacity {
            values.append(value)
        } else {
            values[next] = value
        }
        next = (next + 1) % capacity
    }

    /// Nearest-rank percentiles over the window; nil before the first sample.
    var summary: Summary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func rank(_ p: Double) -> Double { sorted[Swift.min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
        return Summary(count: sorted.count, p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.count - 1])
    }
}

/// One stream's presented frames, counted where they reach the presenter (off the main actor):
/// when the first one showed, how far apart they arrive, how long from decoded to shown, and how
/// many the other Mac numbered that never showed here (a gap in its frame numbers).
nonisolated struct MacScreenFrameTimings: Equatable, Sendable {
    /// Frame intervals and decode-to-present times over the last 120 frames (two seconds at 60 fps).
    static let window = 120

    private(set) var total = 0
    /// When the first frame reached the presenter.
    private(set) var firstPresentedAt: ContinuousClock.Instant?
    private(set) var dropped = 0
    private(set) var intervals = MacScreenRollingSamples(capacity: window)
    private(set) var present = MacScreenRollingSamples(capacity: window)
    private var lastPresentedNanos: UInt64?
    private var lastFrame: UInt32?

    /// A frame (`frame`, the host's number for it, decoded at `decodedAtNanos`) reached the
    /// presenter at `nowNanos` (both `DispatchTime` uptime) and `now`.
    mutating func presented(frame: UInt32, decodedAtNanos: UInt64, nowNanos: UInt64, now: ContinuousClock.Instant) {
        total += 1
        if firstPresentedAt == nil { firstPresentedAt = now }
        if let last = lastPresentedNanos, nowNanos >= last { intervals.add(Double(nowNanos - last) / 1e6) }
        lastPresentedNanos = nowNanos
        if decodedAtNanos > 0, nowNanos >= decodedAtNanos { present.add(Double(nowNanos - decodedAtNanos) / 1e6) }
        // A number past the next one: the frames between never showed. A lower one (the host
        // started over) is a new baseline, not a drop.
        if let last = lastFrame, frame > last, frame - last > 1 { dropped += Int(frame - last - 1) }
        lastFrame = frame
    }
}

/// When a session's connect started and how long until its first frame showed, plus its recent
/// round trips: what `cmux app mac-screens` reports so a viewer's speed can be compared.
nonisolated struct MacScreenConnectTimings: Equatable, Sendable {
    /// Round trips over the last 60 path and status reports.
    static let rttWindow = 60

    /// The steps between the ticket and the first frame, in order.
    enum Step: String, CaseIterable, Sendable {
        /// This side's offer went to the hub.
        case offerSent = "offer_sent"
        /// The host's answer came back.
        case answered
        /// The link's bridge listens: the pane's transport connects.
        case linkReady = "link_ready"
        /// The host's stream started (welcome and started arrived).
        case streaming
    }

    /// Wall clock when this session's connect started (the approved ticket's stream began).
    private(set) var startedAt: Date?
    private(set) var started: ContinuousClock.Instant?
    /// When the person asked (Connect, Try Again): the hub request before the approval and its ticket.
    private(set) var requested: ContinuousClock.Instant?
    /// Connect start to the first decoded frame reaching the screen, in milliseconds.
    private(set) var firstFrameMs: Double?
    /// The person's Connect to the first frame on screen, in milliseconds (nil when the session
    /// started without one, as a quality restart does).
    private(set) var clickToFirstFrameMs: Double?
    /// Each step's time since the connect started, in milliseconds.
    private(set) var stepsMs: [Step: Double] = [:]
    private(set) var rtt = MacScreenRollingSamples(capacity: rttWindow)

    /// A new connect (`requested`: when the person asked for it): everything before it is gone.
    mutating func connectStarted(at wall: Date, _ instant: ContinuousClock.Instant, requested: ContinuousClock.Instant? = nil) {
        self = MacScreenConnectTimings()
        startedAt = wall
        started = instant
        self.requested = requested.flatMap { $0 <= instant ? $0 : nil }
    }

    /// A step reached at `instant`; only its first time after a connect counts.
    mutating func reached(_ step: Step, at instant: ContinuousClock.Instant) {
        guard stepsMs[step] == nil, let started, instant >= started else { return }
        stepsMs[step] = Self.ms(started.duration(to: instant))
    }

    /// The first frame showed at `instant`; only the first one after a connect counts.
    mutating func firstFrame(at instant: ContinuousClock.Instant) {
        guard firstFrameMs == nil, let started, instant >= started else { return }
        firstFrameMs = Self.ms(started.duration(to: instant))
        if let requested { clickToFirstFrameMs = Self.ms(requested.duration(to: instant)) }
    }

    /// Request to ticket, then each step to the next, then the last step to the first frame:
    /// where a slow connect spent its time. Steps not reached are left out.
    var stagesMs: [(String, Double)] {
        guard firstFrameMs != nil || !stepsMs.isEmpty else { return [] }
        var stages: [(String, Double)] = []
        if let requested, let started { stages.append(("request_to_ticket", Self.ms(requested.duration(to: started)))) }
        var last = ("ticket", 0.0)
        for step in Step.allCases {
            guard let at = stepsMs[step] else { continue }
            stages.append(("\(last.0)_to_\(step.rawValue)", (at - last.1).rounded()))
            last = (step.rawValue, at)
        }
        if let firstFrameMs { stages.append(("\(last.0)_to_first_frame", (firstFrameMs - last.1).rounded())) }
        return stages
    }

    private static func ms(_ elapsed: Duration) -> Double {
        (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded()
    }

    mutating func sampleRtt(_ ms: Double?) {
        if let ms { rtt.add(ms) }
    }
}

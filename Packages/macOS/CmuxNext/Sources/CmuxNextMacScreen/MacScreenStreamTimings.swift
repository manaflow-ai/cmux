import CmuxNextRemoteView
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
    /// The viewer's stages on the glass (screen-share design D8), from the drawable's presented
    /// time: release to decoded (Decode), decoded to the glass (Present), and their sum.
    private(set) var decode = MacScreenRollingSamples(capacity: window)
    private(set) var glass = MacScreenRollingSamples(capacity: window)
    private(set) var decodePresent = MacScreenRollingSamples(capacity: window)
    /// Frames whose presented handler ran with no presented time from macOS (the window hidden or
    /// off screen): never on the glass, so left out of Present and Decode + Present.
    private(set) var unpresented = 0
    private var lastPresentedNanos: UInt64?
    private var lastFrame: UInt32?

    /// A frame (`frame`, the host's number for it, released at `releasedAtNanos` and decoded at
    /// `decodedAtNanos`) reached the presenter at `nowNanos` (all `DispatchTime` uptime) and `now`.
    /// Decode is taken here, at decode time, so it never waits on the presented handler.
    mutating func presented(frame: UInt32, releasedAtNanos: UInt64 = 0, decodedAtNanos: UInt64, nowNanos: UInt64,
                            now: ContinuousClock.Instant) {
        total += 1
        if firstPresentedAt == nil { firstPresentedAt = now }
        if releasedAtNanos > 0, releasedAtNanos <= decodedAtNanos { decode.add(Double(decodedAtNanos - releasedAtNanos) / 1e6) }
        if let last = lastPresentedNanos, nowNanos >= last { intervals.add(Double(nowNanos - last) / 1e6) }
        lastPresentedNanos = nowNanos
        if decodedAtNanos > 0, nowNanos >= decodedAtNanos { present.add(Double(nowNanos - decodedAtNanos) / 1e6) }
        // A number past the next one: the frames between never showed. A lower one (the host
        // started over) is a new baseline, not a drop.
        if let last = lastFrame, frame > last, frame - last > 1 { dropped += Int(frame - last - 1) }
        lastFrame = frame
    }

    /// A frame reached the glass: its Present stage and Decode + Present (Decode came with
    /// ``presented(frame:releasedAtNanos:decodedAtNanos:nowNanos:now:)``). Out-of-order times
    /// (a clock that is not the decoder's) are left out, and a frame macOS gave no presented time
    /// is counted in ``unpresented``: the handler's own time is not the glass.
    mutating func shown(_ times: RemoteViewerFrameTimes) {
        guard times.onGlass else { unpresented += 1; return }
        guard times.releasedAtNanos > 0, times.releasedAtNanos <= times.decodedAtNanos,
              times.decodedAtNanos <= times.presentedAtNanos else { return }
        glass.add(Double(times.presentedAtNanos - times.decodedAtNanos) / 1e6)
        decodePresent.add(Double(times.presentedAtNanos - times.releasedAtNanos) / 1e6)
    }
}

/// When a session's connect started and how long until its first frame showed, plus its recent
/// round trips: what `cmux app mac-screens` reports so a viewer's speed can be compared.
nonisolated struct MacScreenConnectTimings: Equatable, Sendable {
    /// Round trips over the last 60 path and status reports.
    static let rttWindow = 60

    /// Wall clock when this session's connect started (the approved ticket's stream began).
    private(set) var startedAt: Date?
    private(set) var started: ContinuousClock.Instant?
    /// Connect start to the first decoded frame reaching the screen, in milliseconds.
    private(set) var firstFrameMs: Double?
    /// Connect start to the end of each stage the connect got past, in milliseconds: `answer` (the host
    /// answered), `link` (the link came up), `frame` (a picture showed). A stage skipped over ends when the
    /// later one does.
    private(set) var stageMs: [MacScreenConnectStage: Double] = [:]
    private(set) var rtt = MacScreenRollingSamples(capacity: rttWindow)

    /// A new connect: everything before it is gone.
    mutating func connectStarted(at wall: Date, _ instant: ContinuousClock.Instant) {
        self = MacScreenConnectTimings()
        startedAt = wall
        started = instant
    }

    /// The first frame showed at `instant`; only the first one after a connect counts.
    mutating func firstFrame(at instant: ContinuousClock.Instant) {
        guard firstFrameMs == nil, let started, instant >= started else { return }
        let elapsed = started.duration(to: instant)
        firstFrameMs = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded()
    }

    /// The connect reached `stage` at `instant`: every stage before it that has no end yet ends now.
    mutating func reached(_ stage: MacScreenConnectStage, at instant: ContinuousClock.Instant) {
        guard let started, instant >= started else { return }
        let elapsed = started.duration(to: instant)
        let ms = (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded()
        for done in MacScreenConnectStage.allCases where done < stage && stageMs[done] == nil { stageMs[done] = ms }
    }

    mutating func sampleRtt(_ ms: Double?) {
        if let ms { rtt.add(ms) }
    }
}

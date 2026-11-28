import Foundation

/// The phone's half of "Mac redraw to iPhone paint": for each redraw the Mac stamped (`pseq`),
/// when its line arrived and when the first frame that showed it was presented. hostd joins
/// these with its own stamps (`phone-frames` `paint` report, PROTOCOL.md).
///
/// A stamped line marks the byte offset its bytes end at in what the session handed the
/// screen; the screen tells it how many of those bytes it had parsed at each present. The first
/// present at or past a mark's offset painted it. Pure and bounded: at most ``maxMarks`` marks
/// wait, a mark waits at most ``maxWaitMs``, a report carries at most ``maxSamples``.
public struct TerminalPaintTally: Sendable, Equatable {
    /// `[seq, received, painted]`, epoch ms (the phone's clock).
    public typealias Sample = [Double]

    public static let maxMarks = 1024
    public static let maxSamples = 200
    public static let maxWaitMs: Double = 5000
    /// A report goes once this many samples wait, or the oldest waited this long.
    public static let reportEveryMs: Double = 5000

    private struct Mark: Sendable, Equatable {
        var seq: Int
        var receivedMs: Double
        var offset: Int
    }

    private var marks: [Mark] = []
    private var samples: [Sample] = []
    private var firstSampleMs: Double?
    /// Bytes handed to the screen so far.
    public private(set) var handed = 0
    /// Marks dropped: never painted within ``maxWaitMs``, or past ``maxMarks``.
    public private(set) var dropped = 0
    /// How old the oldest sample may get before a report goes (``reportEveryMs`` unless the DEBUG
    /// overlay wants its number sooner).
    public var reportIntervalMs: Double

    public init(reportIntervalMs: Double = Self.reportEveryMs) {
        self.reportIntervalMs = reportIntervalMs
    }

    /// `count` more bytes went to the screen.
    public mutating func handed(_ count: Int) {
        handed += count
    }

    /// Redraw `seq` arrived at `receivedMs`; its bytes end at what was handed so far.
    public mutating func mark(seq: Int, receivedMs: Double) {
        if marks.count == Self.maxMarks {
            marks.removeFirst()
            dropped += 1
        }
        marks.append(Mark(seq: seq, receivedMs: receivedMs, offset: handed))
    }

    /// A frame was presented at `atMs` with `parsed` of the handed bytes parsed before it.
    public mutating func presented(parsed: Int, atMs: Double) {
        var painted = 0
        for mark in marks {
            if mark.offset <= parsed {
                if firstSampleMs == nil { firstSampleMs = atMs }
                samples.append([Double(mark.seq), mark.receivedMs, max(atMs, mark.receivedMs)])
                painted += 1
            } else if atMs - mark.receivedMs > Self.maxWaitMs {
                dropped += 1
                painted += 1
            } else {
                break
            }
        }
        if painted > 0 { marks.removeFirst(painted) }
        if samples.count > Self.maxSamples * 2 { samples.removeFirst(samples.count - Self.maxSamples * 2) }
    }

    /// The screen started over (a new mirror): no wait is answered by its counts any more.
    public mutating func reset() {
        dropped += marks.count
        marks.removeAll()
        handed = 0
    }

    /// The samples to report now, if a report is due at `nowMs`.
    public mutating func takeReport(nowMs: Double) -> [Sample]? {
        guard let first = firstSampleMs,
              samples.count >= Self.maxSamples || nowMs - first >= reportIntervalMs else { return nil }
        let out = Array(samples.prefix(Self.maxSamples))
        samples.removeFirst(out.count)
        firstSampleMs = samples.isEmpty ? nil : nowMs
        return out
    }

    /// Every sample so far, without taking them (the simulator harness's own summary).
    public var pending: [Sample] { samples }

    /// p50 and p95 of receive to paint over `samples` (ms), nearest rank.
    public static func receiveToPaint(_ samples: [Sample]) -> (p50: Double, p95: Double)? {
        let values = samples.compactMap { $0.count == 3 ? $0[2] - $0[1] : nil }.sorted()
        guard !values.isEmpty else { return nil }
        func rank(_ p: Double) -> Double {
            values[min(values.count, max(1, Int((p * Double(values.count)).rounded(.up)))) - 1]
        }
        return (rank(0.5), rank(0.95))
    }
}

/// One `phone-frames` paint report line (`{"kind":"paint",...}`).
public struct TerminalPaintReport: Sendable, Equatable {
    public var program: String?
    public var app: String?
    public var load: String?
    public var samples: [TerminalPaintTally.Sample]
    /// `[t0, t1, t2, t3]` clock probes, epoch ms.
    public var clock: [[Double]]
    public var rttMs: Int?
    /// The phone's Agent CLI Screen Changes setting at the report (lean frames when on).
    public var agentCLIHybrid: Bool?

    public init(program: String? = nil, app: String? = nil, load: String? = nil,
                samples: [TerminalPaintTally.Sample], clock: [[Double]] = [], rttMs: Int? = nil,
                agentCLIHybrid: Bool? = nil) {
        self.program = program
        self.app = app
        self.load = load
        self.samples = samples
        self.clock = clock
        self.rttMs = rttMs
        self.agentCLIHybrid = agentCLIHybrid
    }

    public func line() -> Data? {
        var object: [String: Any] = ["v": 1, "kind": "paint", "samples": samples, "clock": clock]
        if let program { object["program"] = program }
        if let app { object["app"] = app }
        if let load { object["load"] = load }
        if let rttMs { object["rtt_ms"] = rttMs }
        if let agentCLIHybrid { object["agent_cli_hybrid"] = agentCLIHybrid }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A clock probe sent at `t0` (phone epoch ms).
    public static func clockProbe(t0: Double) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["kind": "clock", "t0": t0])) ?? Data()
    }

    /// `[t0, t1, t2, t3]` from the Mac's answer, received at `t3`.
    public static func clockSample(answer: Data, t3: Double) -> [Double]? {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let t0 = (object["t0"] as? NSNumber)?.doubleValue,
              let t1 = (object["t1"] as? NSNumber)?.doubleValue,
              let t2 = (object["t2"] as? NSNumber)?.doubleValue else { return nil }
        return [t0, t1, t2, t3]
    }

    public static var nowMs: Double { Date().timeIntervalSince1970 * 1000 }
}

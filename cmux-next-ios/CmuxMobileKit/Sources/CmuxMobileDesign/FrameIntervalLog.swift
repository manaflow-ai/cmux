import Foundation

/// Frame-interval statistics (G-04): the gaps between display frames while
/// something moves, as percentiles and hitch counts. Pure value code so the
/// math is testable on macOS; the iOS recorder below feeds it.
public struct FrameIntervalStats: Codable, Hashable, Sendable {
    public var label: String
    /// Frames counted (intervals, not timestamps).
    public var frames: Int
    /// The display's nominal frame interval (ms), from the link's target.
    public var expectedMs: Double
    public var p50Ms: Double
    public var p90Ms: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var maxMs: Double
    /// Intervals longer than 1.5 frames: at least one frame was dropped.
    public var hitches: Int
    /// Frames the display skipped in all (each interval of n frames skips n - 1).
    public var droppedFrames: Int
    /// Time spent late per second of motion (ms/s), Apple's hitch time ratio.
    public var hitchMsPerSecond: Double
    public var durationSeconds: Double
    /// Every interval (ms, in order), so windows can be pooled later.
    public var intervalsMs: [Double]?
    /// CPU time the main thread used in the window (ms): the app's own work,
    /// which does not depend on how fast the host renders (a simulator's
    /// frame times swing with the Mac's load; this does much less).
    public var mainThreadCPUMs: Double?
    /// Main-thread CPU time (ms) between each pair of frames, in the order of
    /// `intervalsMs`: a frame whose main thread was busy past the frame's
    /// budget was the app's fault, not the renderer's.
    public var mainThreadCPUPerFrameMs: [Double]?

    /// Summarizes `intervals` (seconds). `expected` is the nominal frame interval (seconds).
    public init(label: String, intervals: [Double], expected: Double) {
        self.label = label
        let raw = intervals.map { ($0 * 100_000).rounded() / 100 }
        intervalsMs = raw
        let ms = raw.sorted()
        let expectedMs = expected * 1000
        func percentile(_ p: Double) -> Double {
            guard !ms.isEmpty else { return 0 }
            let rank = min(ms.count - 1, max(0, Int((p * Double(ms.count)).rounded(.up)) - 1))
            return ms[rank]
        }
        frames = ms.count
        self.expectedMs = expectedMs
        p50Ms = percentile(0.50)
        p90Ms = percentile(0.90)
        p95Ms = percentile(0.95)
        p99Ms = percentile(0.99)
        maxMs = ms.last ?? 0
        var hitches = 0
        var dropped = 0
        var late = 0.0
        if expectedMs > 0 {
            for value in ms where value > expectedMs * 1.5 {
                hitches += 1
                dropped += max(1, Int((value / expectedMs).rounded()) - 1)
                late += value - expectedMs
            }
        }
        self.hitches = hitches
        droppedFrames = dropped
        let duration = ms.reduce(0, +) / 1000
        durationSeconds = duration
        hitchMsPerSecond = duration > 0 ? late / duration : 0
    }

    /// One line for logs: `label frames=N p50=.. p95=.. p99=.. max=.. hitches=N dropped=N hitch=Xms/s`.
    public var line: String {
        func f(_ value: Double) -> String { String(format: "%.1f", value) }
        return "\(label) frames=\(frames) expected=\(f(expectedMs))ms p50=\(f(p50Ms)) p90=\(f(p90Ms)) p95=\(f(p95Ms)) "
            + "p99=\(f(p99Ms)) max=\(f(maxMs)) hitches=\(hitches) dropped=\(droppedFrames) hitch=\(f(hitchMsPerSecond))ms/s "
            + "dur=\(f(durationSeconds))s"
    }
}

#if os(iOS)
import Darwin
import OSLog
import QuartzCore

/// Whether frame recording is on for this process: DEBUG builds (Debug, and
/// Demo with its DEBUG condition) with `CMUX_MOBILE_FRAMELOG=1` in the environment
/// (`SIMCTL_CHILD_CMUX_MOBILE_FRAMELOG=1`) or the `-CmuxMobileFrameLog` launch argument.
/// One switch for every recorder (the feed's windows, the terminal's frames).
public enum FrameLogSwitch {
    public static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_MOBILE_FRAMELOG"] == "1" || CommandLine.arguments.contains("-CmuxMobileFrameLog")
        #else
        false
        #endif
    }()
}

/// The one display link every frame recorder reads (G-04): it runs only while
/// someone listens, at up to 120 Hz, and hands each tick's actual and target
/// timestamps to the listeners in subscription order.
@MainActor
public final class FrameClock {
    public static let shared = FrameClock()

    public struct Tick: Sendable {
        /// The frame's actual timestamp (`CADisplayLink.timestamp`).
        public var timestamp: CFTimeInterval
        /// When the next frame is due (`targetTimestamp`).
        public var targetTimestamp: CFTimeInterval
        /// The display's nominal interval for this frame.
        public var nominal: CFTimeInterval { targetTimestamp - timestamp }
    }

    public struct Token: Hashable, Sendable {
        fileprivate let id: Int
    }

    private var link: CADisplayLink?
    private var listeners: [(id: Int, tick: (Tick) -> Void)] = []
    private var nextID = 0

    public init() {}

    public func subscribe(_ tick: @escaping (Tick) -> Void) -> Token {
        nextID += 1
        listeners.append((nextID, tick))
        if link == nil {
            let link = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        return Token(id: nextID)
    }

    public func unsubscribe(_ token: Token) {
        listeners.removeAll { $0.id == token.id }
        if listeners.isEmpty {
            link?.invalidate()
            link = nil
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let tick = Tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        for listener in listeners { listener.tick(tick) }
    }

    /// Breaks the display link's retain of its target.
    @MainActor
    private final class Proxy: NSObject {
        weak var owner: FrameClock?
        init(_ owner: FrameClock) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}

/// Appends recorder output to a file in the app container (read back with
/// `simctl get_app_container`), off the main thread.
public enum FrameLogFile {
    /// One queue, in order, so `flush()` waits for every append (the rig exits right after its last window).
    static let queue = DispatchQueue(label: "dev.cmux.mobile.framelog", qos: .utility)

    /// Waits until every queued append is written.
    public static func flush() { queue.sync {} }

    public static func append(_ data: Data, to url: URL) {
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    public static func url(in directory: FileManager.SearchPathDirectory, _ name: String) -> URL {
        (FileManager.default.urls(for: directory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appending(path: name)
    }
}

/// G-04: frame-interval windows with signposts, for timing claims that do
/// not depend on screen-recording timing (laptop load makes recordings
/// unreliable). On with `FrameLogSwitch`; production compiles it but it is
/// always off and costs nothing. Each `begin`/`end` pair is one window: the
/// summary goes to the `dev.cmux.mobile` `frames` log (`FRAMELOG <line>`) and, as
/// JSON lines, to `Library/Caches/framelog.jsonl` in the app container.
/// Each frame is also an `OSSignposter` event (`frame`, with its interval),
/// and each window an interval (`window`), for Instruments. The terminal's
/// per-frame log (`TerminalFrameLog`) reads the same `FrameClock`.
@MainActor
public final class FrameIntervalLog {
    public static let shared = FrameIntervalLog()

    /// Whether recording is on for this process.
    public let isEnabled: Bool
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")
    private let signposter = OSSignposter(subsystem: "dev.cmux.mobile", category: "frames")
    private var token: FrameClock.Token?
    private var label: String?
    private var lastTimestamp: CFTimeInterval?
    private var intervals: [Double] = []
    private var expected: Double = 1.0 / 60
    private var window: OSSignpostIntervalState?
    private var cpuAtBegin: Double?
    private var cpuAtLastTick: Double?
    private var cpuPerFrame: [Double] = []
    /// Called with every finished window (tests and drivers).
    public var onSummary: ((FrameIntervalStats) -> Void)?

    public init(enabled: Bool? = nil) {
        isEnabled = enabled ?? FrameLogSwitch.isEnabled
    }

    /// Starts a window named `label` (ends the current one first).
    public func begin(_ label: String) {
        guard isEnabled else { return }
        if self.label != nil { end() }
        self.label = label
        intervals = []
        intervals.reserveCapacity(4096)
        lastTimestamp = nil
        cpuAtBegin = Self.mainThreadCPUSeconds()
        cpuAtLastTick = nil
        cpuPerFrame = []
        cpuPerFrame.reserveCapacity(4096)
        window = signposter.beginInterval("window", "\(label, privacy: .public)")
        token = FrameClock.shared.subscribe { [weak self] in self?.tick($0) }
    }

    /// Ends the window and returns its summary (nil when none was open).
    @discardableResult
    public func end() -> FrameIntervalStats? {
        guard isEnabled, let label else { return nil }
        if let token { FrameClock.shared.unsubscribe(token) }
        token = nil
        self.label = nil
        if let window { signposter.endInterval("window", window) }
        window = nil
        var stats = FrameIntervalStats(label: label, intervals: intervals, expected: expected)
        if let cpuAtBegin, let now = Self.mainThreadCPUSeconds() { stats.mainThreadCPUMs = ((now - cpuAtBegin) * 100_000).rounded() / 100 }
        cpuAtBegin = nil
        if cpuPerFrame.count == intervals.count { stats.mainThreadCPUPerFrameMs = cpuPerFrame.map { ($0 * 100_000).rounded() / 100 } }
        log.notice("FRAMELOG \(stats.line, privacy: .public)")
        if var data = try? JSONEncoder().encode(stats) {
            data.append(0x0A)
            FrameLogFile.append(data, to: Self.fileURL)
        }
        onSummary?(stats)
        return stats
    }

    private func tick(_ tick: FrameClock.Tick) {
        // The nominal interval: what the display promised for this frame.
        if tick.nominal > 0.001 { expected = tick.nominal }
        let cpu = Self.mainThreadCPUSeconds()
        if let lastTimestamp {
            let interval = tick.timestamp - lastTimestamp
            intervals.append(interval)
            if let cpu, let cpuAtLastTick { cpuPerFrame.append(cpu - cpuAtLastTick) }
            signposter.emitEvent("frame", "\(interval * 1000, format: .fixed(precision: 2), privacy: .public)")
        }
        lastTimestamp = tick.timestamp
        cpuAtLastTick = cpu
    }

    /// User plus system CPU time of the calling (main) thread, in seconds.
    private static func mainThreadCPUSeconds() -> Double? {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        func seconds(_ value: time_value_t) -> Double { Double(value.seconds) + Double(value.microseconds) / 1_000_000 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// JSON lines next to the app's caches, read back with `simctl get_app_container`.
    public static var fileURL: URL { FrameLogFile.url(in: .cachesDirectory, "framelog.jsonl") }
}
#endif

public import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation

/// Chromium's own trace in Release (plans/cmux-next/chrome-parity/p09-observability.md, task 051): a
/// `trace.start chromium:true` begins it where `CefInitialize` ran, and `trace.stop` ends it into the
/// recording directory as Chromium's JSON trace, with the clock offset in a `.meta.json` beside it.
///
/// Chrome's tracing consumer takes the same steps (content/browser/tracing/tracing_controller_impl.cc):
/// `StartTracing` with a category filter, `StopTracing` into a file endpoint, and a clock sync
/// (`Tracing.recordClockSyncMarker`, content/browser/devtools/protocol/tracing_handler.cc) that puts the trace on
/// the consumer's clock. Role-aware: in process the app calls the shim's tracing exports (task 050); with
/// the Chromium Host on, the host calls them for its TRACE_START and TRACE_STOP wire frames
/// (``ChromiumHostTracing``, task 104). A shim or host without them reports ``CEFTracingError/unsupported(_:)``.
///
/// ```swift
/// let tracing = CEFTracing(directory: blackBox.directory, work: work)
/// let started = try await tracing.start()
/// let stopped = try await tracing.stop() // stopped.path, stopped.clock?.offsetNanos
/// ```
public final class CEFTracing {
    /// Chromium's categories: top-level task slices, the frame pipeline (cc, viz, gpu), input with its
    /// LatencyInfo flows, and the benchmark marks.
    public static let categories = "toplevel,cc,viz,gpu,input,latencyInfo,benchmark"
    /// The buffer the plan asks for, 64 MB. Stock `CefBeginTracing` takes none (libcef/browser/trace_subscriber.cc
    /// builds `TraceConfig(categories, "")`), so Chromium's record-until-full default applies; meta.json says so.
    public static let requestedBufferKB = 64 * 1024

    private let directory: String
    private let pid: Int32
    private let work: any MayBlockRunner
    private let clock: TraceClock
    private let backend: () -> Backend
    private var phase: Phase = .idle

    /// Chromium tracing for this process's Chromium (``CEFRuntime``), in process or through its host.
    ///
    /// - Parameters:
    ///   - directory: The recording directory (the black box's): the JSON trace and its meta.json go there.
    ///   - work: The blocking-work lanes the directory and meta.json writes run on.
    public convenience init(directory: String, work: any MayBlockRunner) {
        self.init(directory: directory, work: work) { CEFRuntime.shared.tracingBackend(hostWire: nil) }
    }

    /// - Parameters:
    ///   - backend: Where tracing runs, read at each start (Chromium may start or change role between recordings).
    ///   - clock: The local trace clock the offset is measured against (tests inject a reader).
    init(directory: String, work: any MayBlockRunner, pid: Int32 = getpid(), clock: TraceClock = TraceClock(),
         backend: @escaping () -> Backend) {
        self.directory = directory
        self.pid = pid
        self.work = work
        self.clock = clock
        self.backend = backend
    }

    /// The JSON trace's file: Chromium's end needs an absolute path that ends in `.json`.
    var tracePath: String { directory + "/chromium-\(pid).trace.json" }
    /// The meta.json beside it.
    var metaPath: String { directory + "/chromium-\(pid).meta.json" }

    /// Begins Chromium tracing with ``categories`` and samples the clock offset.
    public func start() async throws(CEFTracingError) -> Started {
        guard case .idle = phase else { throw phase.isRecording ? CEFTracingError.alreadyTracing : CEFTracingError.busy }
        let route: Route
        switch backend() {
        case .unsupported(let reason): throw .unsupported(reason)
        case .inProcess(let tracing): route = .inProcess(tracing)
        case .host(let wire): route = .host(wire)
        }
        phase = .changing
        guard await route.begin(Self.categories) else {
            phase = .idle
            throw .refused
        }
        let sample = await route.sample(clock)
        phase = .recording(Session(route: route, startSample: sample))
        return Started(mode: route.mode, categories: Self.categories, clock: sample)
    }

    /// Ends Chromium tracing into ``tracePath`` and writes the offset to ``metaPath``.
    public func stop() async throws(CEFTracingError) -> Stopped {
        guard case .recording(let session) = phase else { throw phase.isChanging ? CEFTracingError.busy : CEFTracingError.notTracing }
        phase = .changing
        defer { phase = .idle }
        let stopSample = await session.route.sample(clock)
        let directory = directory
        // CefEndTracing writes into the folder but does not make it.
        _ = try? await work.runFiles(.userVisible) {
            try FileManager.checked.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        guard let written = await session.route.end(tracePath) else { throw .notWritten }
        let best = ClockSample.tighter(session.startSample, stopSample)
        let meta = Meta(mode: session.route.mode, pid: pid, trace: URL(fileURLWithPath: written).lastPathComponent,
                        categories: Self.categories, requestedBufferKB: Self.requestedBufferKB, clock: best,
                        samples: [session.startSample, stopSample].compactMap { $0 })
        let metaPath = metaPath
        var wrote = false
        if let data = try? meta.encoded() {
            wrote = (try? await work.runFiles(.userVisible) { try data.blockingWrite(to: URL(fileURLWithPath: metaPath), options: .atomic) }) != nil
        }
        return Stopped(mode: session.route.mode, path: written, metaPath: wrote ? metaPath : nil, clock: best)
    }
}

extension CEFTracing {
    /// Where tracing runs: the process that ran `CefInitialize`.
    enum Backend {
        /// The app ran `CefInitialize`: the in-process shim's exports.
        case inProcess(CEFShimTracing)
        /// The Chromium Host ran it: its TRACE_START and TRACE_STOP frames.
        case host(any ChromiumHostTracing)
        case unsupported(CEFTracingError.Unsupported)
    }

    /// The backend a recording began on; its stop ends there too.
    enum Route {
        case inProcess(CEFShimTracing)
        case host(any ChromiumHostTracing)

        var mode: Mode {
            switch self {
            case .inProcess: .inProcess
            case .host: .host
            }
        }

        func begin(_ categories: String) async -> Bool {
            switch self {
            case .inProcess(let tracing): await tracing.begin(categories: categories)
            case .host(let wire): await wire.beginTracing(categories: categories)
            }
        }

        func end(_ path: String) async -> String? {
            switch self {
            case .inProcess(let tracing): await tracing.end(path: path)
            case .host(let wire): await wire.endTracing(path: path)
            }
        }

        /// Chromium's clock read between two local reads; nil when the host did not answer.
        func sample(_ clock: TraceClock) async -> ClockSample? {
            let before = clock.nowNanos()
            let chromium: Int64?
            switch self {
            case .inProcess(let tracing): chromium = tracing.now()
            case .host(let wire): chromium = await wire.nowTraceMicros()
            }
            let after = clock.nowNanos()
            return chromium.map { ClockSample(before: before, chromiumMicros: $0, after: after) }
        }
    }

    struct Session {
        let route: Route
        let startSample: ClockSample?
    }

    enum Phase {
        case idle
        /// A start or a stop is reaching Chromium.
        case changing
        case recording(Session)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isChanging: Bool {
            if case .changing = self { return true }
            return false
        }
    }
}

extension CEFRuntime {
    /// Where Chromium tracing runs now: the in-process shim's exports, the host's wire in host mode, or why
    /// neither can. `hostWire` is the host's TRACE_START and TRACE_STOP (task 104); nil until the host has them.
    func tracingBackend(hostWire: (any ChromiumHostTracing)?) -> CEFTracing.Backend {
        guard state == .ready, let shim else { return .unsupported(.chromiumNotRunning) }
        if hostStart != nil { return hostWire.map { .host($0) } ?? .unsupported(.noHostWire) }
        return shim.tracing.map { .inProcess($0) } ?? .unsupported(.missingShimSymbol)
    }
}

/// Chromium tracing in the Chromium Host (task 104): its TRACE_START and TRACE_STOP wire frames call the
/// shim's tracing exports (task 050) in the host, which ran `CefInitialize`.
protocol ChromiumHostTracing {
    /// TRACE_START: begins tracing `categories`; true when every Chromium process records.
    func beginTracing(categories: String) async -> Bool
    /// TRACE_STOP: ends tracing into `path` (absolute, `.json`); the finished file, nil when none was written.
    func endTracing(path: String) async -> String?
    /// The host's `cmux_cef_now_trace_us`, nil when the host did not answer.
    func nowTraceMicros() async -> Int64?
}

/// Why Chromium tracing did not start or stop.
public nonisolated enum CEFTracingError: Error, Equatable, Sendable {
    /// This Chromium cannot trace.
    case unsupported(Unsupported)
    /// A recording already runs.
    case alreadyTracing
    /// A start or a stop is still reaching Chromium.
    case busy
    /// No recording runs.
    case notTracing
    /// Chromium refused the start (or was not running to take it).
    case refused
    /// Chromium wrote no trace file.
    case notWritten

    /// Why this Chromium cannot trace.
    public enum Unsupported: String, Sendable {
        /// Chromium has not started in this process (or stopped).
        case chromiumNotRunning = "chromium_not_running"
        /// The in-process shim predates the tracing exports (task 050).
        case missingShimSymbol = "missing_shim_symbol"
        /// The Chromium Host has no TRACE_START wire (task 104).
        case noHostWire = "no_host_wire"
    }

    /// The reply's error code.
    public var code: String {
        switch self {
        case .unsupported: "unsupported"
        case .alreadyTracing: "already_tracing"
        case .busy: "busy"
        case .notTracing: "not_tracing"
        case .refused: "refused"
        case .notWritten: "not_written"
        }
    }
}

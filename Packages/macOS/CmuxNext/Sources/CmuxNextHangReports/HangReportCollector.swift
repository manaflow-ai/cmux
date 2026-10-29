public import CmuxNextCompat
public import CmuxNextTrace
import Foundation

/// Receives the watchdog's stalls and hangs, the blocking detector's new call sites and each
/// launch's milestones (``noteLaunch(_:)``) while hang reports are on, into a ``StallAggregate``
/// that ``HangReportService`` drains into each report.
///
/// ``noteStall(durationNanos:cpuNanos:addresses:startup:)`` runs on the main thread at the end of each
/// stall over the watchdog's threshold: off, it is one atomic load; on, a lock over a few integer
/// adds. Only a stall that earns a stack slot (250 ms and up, among the longest 8) leaves the
/// main thread: its addresses are reduced to ``HangReportFrame``s on a utility task (`resolve`, which
/// reads dyld and the classifier) and kept after that. ``noteBlocking(_:)`` runs on the detector's
/// drain queue, already off the main thread, and resolves there. Nothing here runs while the app is idle.
///
/// A hang of ``blackBoxHangMs`` or more (at its end in ``noteStall(durationNanos:cpuNanos:addresses:startup:)``, or still
/// running in ``noteHang(durationNanos:addresses:task:startup:)``), or a key frame over ``blackBoxKeyFrameMicros``, takes the
/// merged black box once per report (schema 3's `blackbox[]`): the trigger is one more check
/// under the lock, and the rings are read by `captureBlackBox` off the main thread.
///
/// ```swift
/// let collector = HangReportCollector(resolve: { addresses in frames(for: addresses) })
/// watchdog.onStall = { collector.noteStall(durationNanos: $0.nanos, cpuNanos: $0.cpuNanos, addresses: $0.addresses) }
/// ```
public final class HangReportCollector: Sendable {
    /// Turns return addresses (innermost first) into report frames. Called off the main thread.
    public typealias Resolve = @Sendable ([UInt]) -> [HangReportFrame]
    /// Turns a blocking detector stack (image UUID + offset) into report frames. Called off the main thread.
    public typealias ResolveBlocking = @Sendable ([BlockingFrame]) -> [HangReportFrame]
    /// Reads the merged black box (``HangReportFieldSources/captureBlackBox()``).
    public typealias CaptureBlackBox = @Sendable () async -> [TraceBlackBoxUpload.Record]
    /// Turns another process's frames (image name, UUID and offset, as its hang line names them) into report frames
    /// through the classifier, as a MetricKit frame is: the image is not loaded here. Called off the main thread.
    public typealias ResolveForeign = @Sendable ([ForeignFrame]) -> [HangReportFrame]

    /// One frame of another process's stack, innermost first: what a Rust hang line (`hangs-<pid>.jsonl`) gives.
    public struct ForeignFrame: Sendable, Equatable {
        /// The image's file name; nil when the address is in no loaded image.
        public var image: String?
        /// The image's `LC_UUID`; nil with no image.
        public var uuid: String?
        /// The address minus the image's load address; nil with no image.
        public var offset: UInt64?

        /// Makes the value from its parts.
        public init(image: String?, uuid: String?, offset: UInt64?) {
            self.image = image
            self.uuid = uuid
            self.offset = offset
        }
    }

    /// A hang this long (ms) takes the black box.
    public static let blackBoxHangMs = 1_000
    /// A key frame longer than this (µs) takes the black box.
    public static let blackBoxKeyFrameMicros: UInt64 = 50_000

    /// What the lock guards: the findings, and the black box taken since the last report.
    private struct State {
        var aggregate = StallAggregate()
        /// The records taken at the first trigger since ``takeBlackBox()``; nil before one.
        var blackBox: [TraceBlackBoxUpload.Record]?
        /// A capture runs: later triggers add nothing.
        var capturing = false
    }

    private let enabled = Atomic<Bool>(false)
    /// Whether ``setEnabled(_:)`` ran: until the setting is first read, blocking sites and other processes' hangs are
    /// kept (at most ``StallAggregate/maxSamples``), so what the detector and the Rust diagnostics forwarder replay at
    /// launch is not lost; the first `setEnabled(false)` drops them.
    private let decided = Atomic<Bool>(false)
    // Lock carve-out: a synchronous count from the main thread's run-loop observer at a stall's
    // end; an actor would add a Task and a hop per stall.
    private let state = Mutex(State())
    private let resolve: Resolve
    /// Nil when the report's wire schema has no blocking samples: then none is kept.
    private let resolveBlocking: ResolveBlocking?
    /// Runs a resolution job; the default is a detached utility task. Tests run it inline.
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    /// Nil when the report's wire schema has no black box: then no trigger takes one.
    private let captureBlackBox: CaptureBlackBox?
    /// False when the report's wire schema has no watched threads' hangs: then none is kept.
    private let keepsThreadHangs: Bool
    /// Nil: no other process's hang is kept.
    private let resolveForeign: ResolveForeign?
    /// Runs a black-box capture; the default is a utility task. Tests keep the job and await it.
    private let scheduleCapture: @Sendable (@escaping @Sendable () async -> Void) -> Void

    /// Makes the value from its parts.
    ///
    /// - Parameter resolveBlocking: Nil (the default) keeps no blocking site, for a report whose wire
    ///   schema has none (``HangReport/WireSchema/carriesBlocking``); the app passes
    ///   ``HangReportBuilder/frames(blocking:)`` when its builder's schema carries them.
    /// - Parameter captureBlackBox: Nil (the default) takes no black box, for a report whose wire schema has
    ///   none (``HangReport/WireSchema/carriesFieldData``).
    /// - Parameter keepsThreadHangs: False (the default) keeps no watched thread's hang, for a report whose wire
    ///   schema has none (``HangReport/WireSchema/carriesThreadHangs``).
    /// - Parameter resolveForeign: Nil (the default) keeps no other process's hang (``noteProcessHang(durationMs:frames:thread:)``);
    ///   the app passes the builder's classifier over MetricKit-style frames.
    public init(resolve: @escaping Resolve,
                resolveBlocking: ResolveBlocking? = nil,
                captureBlackBox: CaptureBlackBox? = nil,
                keepsThreadHangs: Bool = false,
                resolveForeign: ResolveForeign? = nil,
                schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { job in
                    // task-owner: one short resolution per sampled stall; nothing to cancel.
                    Task.detached(priority: .utility) { job() }
                },
                scheduleCapture: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = { job in
                    // task-owner: at most one ring read per report; it ends when the read does.
                    Task(priority: .utility) { await job() }
                }) {
        self.resolve = resolve
        self.resolveBlocking = resolveBlocking
        self.captureBlackBox = captureBlackBox
        self.keepsThreadHangs = keepsThreadHangs
        self.resolveForeign = resolveForeign
        self.schedule = schedule
        self.scheduleCapture = scheduleCapture
    }

    /// Whether stalls are recorded.
    public var isEnabled: Bool { enabled.load(ordering: .relaxed) }

    /// Turns recording on or off; off drops what was recorded.
    public func setEnabled(_ on: Bool) {
        decided.store(true, ordering: .relaxed)
        enabled.store(on, ordering: .relaxed)
        if !on { state.withLock { $0 = State() } }
    }

    /// One new blocking call site (the detector's drain queue, from the app's `BlockingReportSink`):
    /// kept once as a ``HangSample/Kind/blocking`` sample with its kind, context and frames; a site
    /// already kept adds nothing, and nothing is kept when the wire schema has no blocking samples.
    public func noteBlocking(_ violation: BlockingViolation) {
        guard let resolveBlocking, acceptsUndecided else { return }
        let sample = HangSample.blockingSite(HangSample.Blocking(violation), frames: resolveBlocking(violation.frames))
        // Checked again under the lock the drop of setEnabled(false) takes: a site resolved while
        // reports turned off is not kept after the drop.
        state.withLock { state in
            guard acceptsUndecided else { return }
            state.aggregate.keep(sample)
        }
    }

    /// One daemon site (``DaemonDiagnosticSite``, from the app's `BlockingReportSink` on a background lane): kept
    /// once as a ``HangSample/Source/daemon`` sample, under the blocking samples' rules (none when the wire
    /// schema has no blocking samples, kept before the setting is read, a site already kept adds nothing).
    public func noteDaemonSite(_ site: DaemonDiagnosticSite) {
        guard resolveBlocking != nil, acceptsUndecided else { return }
        let sample = HangSample.daemonSite(site)
        state.withLock { state in
            guard acceptsUndecided else { return }
            state.aggregate.keep(sample)
        }
    }

    /// On, or the setting not read yet: what launch replays (blocking sites, other processes' hang lines) is kept.
    private var acceptsUndecided: Bool {
        isEnabled || !decided.load(ordering: .relaxed)
    }

    /// One finished stall (main thread, from the watchdog's `onStall`), with where the launch was when it
    /// ran before startup completed (nil after).
    public func noteStall(durationNanos: UInt64, cpuNanos: UInt64, addresses: [UInt], startup: HangSample.Startup? = nil) {
        guard isEnabled else { return }
        let ms = Self.milliseconds(durationNanos)
        // A stall of a hang's length is only counted: its stack came from `noteHang`, sampled
        // while it ran, which shows where it was stuck rather than where it started.
        let sample = state.withLock { state in
            state.aggregate.count(durationMs: ms)
            return !addresses.isEmpty && ms < StallAggregate.hangMs && state.aggregate.wantsStallSample(durationMs: ms)
        }
        // Every hang ends here with its full length; `noteHang` sees only the ones still running at the watchdog's
        // threshold, at most one per its report interval.
        if ms >= Self.blackBoxHangMs { startBlackBoxCapture() }
        guard sample else { return }
        keepLater(HangSample(source: .watchdog, kind: .stall, durationMs: ms, cpuMs: Self.milliseconds(cpuNanos), frames: [],
                             startup: startup),
                  addresses: addresses)
    }

    /// One hang still running (watchdog thread, from the watchdog's `onHang`), with the scheduled task it
    /// caught (``HangSample/MainTask/unattributed`` when none ran; nil when the caller does not know) and where the
    /// launch was before startup completed (nil after). A hang that never ends takes the black box here.
    public func noteHang(durationNanos: UInt64, addresses: [UInt], task: HangSample.MainTask? = nil,
                         startup: HangSample.Startup? = nil) {
        guard isEnabled else { return }
        let ms = Self.milliseconds(durationNanos)
        if ms >= Self.blackBoxHangMs { startBlackBoxCapture() }
        guard !addresses.isEmpty, state.withLock({ $0.aggregate.wantsHangSample(durationMs: ms) }) else { return }
        keepLater(HangSample(source: .watchdog, kind: .hang, durationMs: ms, frames: [], mainTask: task, startup: startup),
                  addresses: addresses)
    }

    /// One watched thread still in its hang-watch scope 2 s past its budget (watchdog thread, from the watchdog's
    /// `onThreadHang`): kept in its own slots apart from the main thread's hangs (``StallAggregate/threadHangs``),
    /// longest first, as a ``HangSample/Source/hangWatch`` sample that names `thread`; nothing when the wire schema
    /// has none. `durationNanos` is how far past its budget the scope was when its stack was sampled. The scope has
    /// run 2 s past its budget, a hang by any measure: it takes the black box as a main-thread hang does.
    public func noteThreadHang(durationNanos: UInt64, addresses: [UInt], thread: HangSample.WatchedThread) {
        guard isEnabled, keepsThreadHangs else { return }
        startBlackBoxCapture()
        let ms = Self.milliseconds(durationNanos)
        guard !addresses.isEmpty, state.withLock({ $0.aggregate.wantsThreadHangSample(durationMs: ms) }) else { return }
        keepLater(.threadHang(thread, durationMs: ms, frames: []), addresses: addresses)
    }

    /// One hang of the Chromium Host's UI thread, 250 ms or longer (main thread): the host
    /// measured it and sends no stack (its stack is in the host's own dump at 10 s), so it is kept frameless, as a
    /// watched thread's hang named ``hostUIThread``, in the thread hang slots: it never pushes the app's own main
    /// thread hang out, and it counts in none of the app's histograms. Nothing when the wire schema has none.
    public func noteHostHang(durationNanos: UInt64) {
        guard isEnabled, keepsThreadHangs else { return }
        let ms = Self.milliseconds(durationNanos)
        state.withLock { state in
            guard state.aggregate.wantsThreadHangSample(durationMs: ms) else { return }
            state.aggregate.keep(.threadHang(Self.hostUIThread, durationMs: ms, frames: []))
        }
    }

    /// The Chromium Host's UI thread in a hang report: the host's main thread.
    public static let hostUIThread = HangSample.WatchedThread(name: "chromium-host.ui", kind: "main")

    /// One watched thread of another cmux process (a Rust process's `hangs-<pid>.jsonl` line, read by the app's
    /// Rust diagnostics forwarder on its utility queue) whose scope ran `durationMs` past its deadline: kept with the
    /// watched threads' hangs (``StallAggregate/threadHangs``) as a ``HangSample/Source/hangWatch`` sample that names
    /// `thread`, its frames classified here. Nothing when the wire schema has no thread hangs, there is no foreign
    /// resolver, or the line has no stack (Linux and Windows record none). On, it takes the black box as
    /// ``noteThreadHang(durationNanos:addresses:thread:)`` does.
    ///
    /// Until the setting is first read (``setEnabled(_:)``) it is kept as a blocking site is: the forwarder reads the
    /// lines other processes wrote while the app was not running at launch, before the setting loads, and the first
    /// `setEnabled(false)` drops them.
    public func noteProcessHang(durationMs: Int, frames: [ForeignFrame], thread: HangSample.WatchedThread) {
        guard acceptsUndecided, keepsThreadHangs, let resolveForeign else { return }
        if isEnabled { startBlackBoxCapture() }
        let ms = min(max(durationMs, 0), HistogramBucket.maxMs)
        guard !frames.isEmpty, state.withLock({ $0.aggregate.wantsThreadHangSample(durationMs: ms) }) else { return }
        let sample = HangSample.threadHang(thread, durationMs: ms, frames: Array(resolveForeign(frames).prefix(HangSample.maxFrames)))
        state.withLock { state in
            // Reports turned off while the frames were classified: not kept after the drop.
            guard acceptsUndecided else { return }
            state.aggregate.keep(sample)
        }
    }

    /// One launch at its `startup_complete` (main thread, once per launch). Off, it is one atomic
    /// load; on, the lock over a few small array merges. An interrupted launch adds only its reason.
    /// The app calls it from task p08-startup-115; a report carries the launches only in
    /// ``HangReport/WireSchema/v3``.
    public func noteLaunch(_ launch: LaunchAggregate.Record) {
        guard isEnabled else { return }
        state.withLock { $0.aggregate.record(launch: launch) }
    }

    /// One key frame (`key.frame`, key-down to its commit): over ``blackBoxKeyFrameMicros`` it takes the black
    /// box, unless one was taken since the last report. Off, one atomic load.
    public func noteKeyFrame(durationMicros: UInt64) {
        guard durationMicros > Self.blackBoxKeyFrameMicros, isEnabled else { return }
        startBlackBoxCapture()
    }

    /// Starts one capture when none is held or running: the first trigger since the last report wins, so a
    /// storm of slow frames reads the rings once.
    private func startBlackBoxCapture() {
        guard let captureBlackBox, state.withLock({ state in
            guard state.blackBox == nil, !state.capturing else { return false }
            state.capturing = true
            return true
        }) else { return }
        scheduleCapture { [self] in
            let records = await captureBlackBox()
            state.withLock { state in
                // Reports turned off meanwhile replaced the state: the records are not kept.
                guard state.capturing else { return }
                state.capturing = false
                if isEnabled { state.blackBox = records }
            }
        }
    }

    /// Takes the black box taken since the last report (empty when none), and lets the next trigger take one.
    public func takeBlackBox() -> [TraceBlackBoxUpload.Record] {
        state.withLock { state in
            defer { state.blackBox = nil }
            return state.blackBox ?? []
        }
    }

    /// A copy of the black box taken since the last report, for a preview or a report not queued yet.
    public func blackBoxSnapshot() -> [TraceBlackBoxUpload.Record] {
        state.withLock { $0.blackBox ?? [] }
    }

    /// `sent` (a ``blackBoxSnapshot()``) is in a queued report: the black box is released when it is still that one,
    /// so the next trigger takes a new one.
    public func releaseBlackBox(sent: [TraceBlackBoxUpload.Record]) {
        state.withLock { state in
            if state.blackBox == sent { state.blackBox = nil }
        }
    }

    /// Puts back the black box an earlier launch saved at quit (``HangReportService/saveForNextLaunch()``), unless
    /// one was taken or is being taken since.
    public func restoreBlackBox(_ saved: [TraceBlackBoxUpload.Record]) {
        guard isEnabled, captureBlackBox != nil, !saved.isEmpty else { return }
        state.withLock { state in
            guard state.blackBox == nil, !state.capturing else { return }
            state.blackBox = saved
        }
    }

    /// Takes what was recorded and starts over.
    public func drain() -> StallAggregate {
        state.withLock { state in
            let taken = state.aggregate
            state.aggregate = StallAggregate()
            return taken
        }
    }

    /// Adds a saved aggregate (the previous launch's) to what is recorded now.
    public func merge(_ saved: StallAggregate) {
        var saved = saved
        // A build whose schema had blocking samples or thread hangs saved them; this one cannot send them.
        if resolveBlocking == nil { saved.dropBlocking() }
        if !keepsThreadHangs { saved.dropThreadHangs() }
        guard isEnabled, !saved.isEmpty else { return }
        state.withLock { $0.aggregate.merge(saved) }
    }

    /// A copy of what is recorded, for a preview.
    public func snapshot() -> StallAggregate { state.withLock { $0.aggregate } }

    private func keepLater(_ sample: HangSample, addresses: [UInt]) {
        let resolve = resolve
        schedule { [self] in
            var resolved = sample
            resolved.frames = Array(resolve(addresses).prefix(HangSample.maxFrames))
            guard isEnabled else { return }
            state.withLock { $0.aggregate.keep(resolved) }
        }
    }

    static func milliseconds(_ nanos: UInt64) -> Int { Int(min(nanos / 1_000_000, UInt64(HistogramBucket.maxMs))) }
}

import CoreFoundation
import Darwin
import Foundation
import os
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextWakeups

/// Records every main-thread stall longer than `threshold` (default 50 ms)
/// with a stack sample, into a ring buffer (`debug.hangs`).
///
/// `CFRunLoopObserver`s on the main run loop stamp a heartbeat at every
/// run-loop activity (the before-waiting stamp after AppKit's display and
/// the Core Animation commit). Time between two stamps while the loop is not asleep
/// is main-thread work; a gap over the threshold is a stall, measured
/// exactly on the main thread when it ends. A dedicated watchdog thread
/// parks until a main-thread turn outlasts the sample delay (a one-shot
/// kernel timer the main thread arms when its run loop wakes and deletes
/// before it sleeps, ``MainThreadWatchdogAlarm``), so a short turn wakes no
/// other thread and an idle app costs it nothing. While a turn runs past the
/// delay it checks once per threshold whether the heartbeat stopped; if so it
/// samples the main thread's stack mid-stall.
public final class MainThreadWatchdog: Sendable {
    public struct Configuration: Sendable {
        public var threshold: Duration
        public var capacity: Int
        public var sampleStacks: Bool
        public var logStalls: Bool
        /// A stall still running this long is a hang: the watchdog thread
        /// reports it (``MainThreadWatchdog/onHang``) WHILE it runs, since a
        /// hang that never ends is never recorded as a stall. Default 2 s.
        public var hangThreshold: Duration
        /// At most one hang report per this interval. Default zero: every hang is
        /// reported (2026-10-30: at 5 min, three hangs in 30 s reached Sentry as
        /// one); the app's sink budgets a flood (`MainThreadHangReporter`).
        public var hangReportInterval: Duration
        /// Debug builds: a hang still running this long fails an assertion
        /// (default 10 s; nil in release builds), if the main thread used
        /// CPU for at least half of it (``hangFailsAssertion(elapsedNanos:mainThreadCPUNanos:assertNanos:)``).
        public var hangAssertThreshold: Duration?

        /// `CMUX_NEXT_HANG_THRESHOLD_MS` lowers the threshold for a
        /// diagnostic launch (for example 8 to sample one-frame stalls);
        /// the default is 50 ms.
        public static var environmentThreshold: Duration {
            let raw = ProcessInfo.processInfo.environment["CMUX_NEXT_HANG_THRESHOLD_MS"].flatMap(Int.init) ?? 50
            return .milliseconds(min(max(raw, 4), 1_000))
        }

        /// The debug assertion is useful for interactive launches, but a
        /// `CMUX_NEXT_NO_ACTIVATE=1` diagnostic launch must stay alive long
        /// enough to preserve its watchdog evidence after reporting a hang.
        public static var defaultHangAssertThreshold: Duration? {
            hangAssertThreshold(debugBuild: ControlService.isDebugBuild,
                                noActivate: ProcessInfo.processInfo.environment["CMUX_NEXT_NO_ACTIVATE"] == "1")
        }

        /// Policy seam kept explicit so diagnostic-launch behavior is tested
        /// without mutating the process environment.
        public static func hangAssertThreshold(debugBuild: Bool, noActivate: Bool) -> Duration? {
            debugBuild && !noActivate ? .seconds(10) : nil
        }

        public init(threshold: Duration = Configuration.environmentThreshold, capacity: Int = 128, sampleStacks: Bool = true,
                    logStalls: Bool = ControlService.isDebugBuild, hangThreshold: Duration = .seconds(2),
                    hangReportInterval: Duration = .zero,
                    hangAssertThreshold: Duration? = Configuration.defaultHangAssertThreshold) {
            self.threshold = threshold
            self.capacity = capacity
            self.sampleStacks = sampleStacks
            self.logStalls = logStalls
            self.hangThreshold = hangThreshold
            self.hangReportInterval = hangReportInterval
            self.hangAssertThreshold = hangAssertThreshold
        }
    }

    /// A main-thread hang in progress: how long the main thread has been
    /// busy so far, and its stack (return addresses, innermost first).
    public struct Hang: Sendable {
        public var duration: Duration
        public var addresses: [UInt]
        /// Every other thread's stack, sampled right after the main thread's: a main thread
        /// that waits on a lock or a reply shows only the wait, and the holder is in here
        /// (``ThreadStackSampler/sampleOtherThreads(excluding:maxFrames:)``).
        public var otherThreads: [ThreadSample] = []
    }

    public let configuration: Configuration
    /// Receives each reported hang on the watchdog thread (the app sends it
    /// to crash reporting). Called at most once per stall and once per
    /// `hangReportInterval`; it must not wait for the main thread.
    public var onHang: (@Sendable (Hang) -> Void)? {
        get { hangSink.withLock { $0 } }
        set { hangSink.withLock { $0 = newValue } }
    }
    private let hangSink = Mutex<(@Sendable (Hang) -> Void)?>(nil)
    /// Receives each finished stall (a ``HangRecord`` of kind `stall`, with
    /// its raw stack) on the MAIN thread, right after the stall ended: the
    /// app sends lag spikes to crash reporting. It must return at once: no
    /// symbolication, I/O or allocation-heavy work on this thread.
    public var onStall: (@Sendable (HangRecord) -> Void)? {
        get { stallSink.withLock { $0 } }
        set { stallSink.withLock { $0 = newValue } }
    }
    private let stallSink = Mutex<(@Sendable (HangRecord) -> Void)?>(nil)
    let episodeSink = Mutex<HangEpisodeRecorder?>(nil) // ``episodes``
    /// Finished stalls of a hang's length by beat, the newest few, until their file takes one (+Episodes).
    let hangEnds = Mutex<[(beat: UInt64, nanos: UInt64, cpuNanos: UInt64)]>([])
    /// The process's fault counters when the watchdog first sampled the stall of `beat`: the
    /// base of its hang file's page-ins (+Episodes). Watchdog thread only (uncontended).
    let stallEvents = Mutex<(beat: UInt64, counts: TaskEventCounts?)?>(nil)
    private let hangNanos: UInt64
    let hangIntervalNanos: UInt64
    private let hangAssertNanos: UInt64?
    public let log: HangLog
    /// Busy windows (CPU with no input, animation or output) share the log.
    public let busy: BusyWatchdog
    private let thresholdNanos: UInt64
    /// `CLOCK_UPTIME_RAW` nanoseconds; tests inject a clock that moves only
    /// when they move it, so host load adds no stall.
    private let uptime: @Sendable () -> UInt64
    /// The stack is sampled this long into a stall (60% of the threshold),
    /// so a stall that ends just past the threshold still has one; the
    /// sample is dropped when the stall ends below the threshold.
    private let sampleAfterNanos: UInt64
    // Heartbeat, written by the main-thread observer.
    private let beatNanos = Atomic<UInt64>(0)
    let beatSequence = Atomic<UInt64>(0)
    /// Main-thread CPU time at the last heartbeat (CLOCK_THREAD_CPUTIME_ID).
    private let beatCPUNanos = Atomic<UInt64>(0)
    /// Main-thread work gaps longer than one 60 Hz frame (16.7 ms) but not
    /// necessarily stalls: they drop frames. Counted, not sampled.
    private let longFrames = Atomic<UInt64>(0)
    private let longFrameMaxNanos = Atomic<UInt64>(0)
    static let frameNanos: UInt64 = 16_666_667
    /// Main-thread work gaps longer than one 120 Hz frame (8.3 ms), and the
    /// longest gap of any length: the stall bench's per-action numbers
    /// (scripts/cmux-next/bench-stalls.py).
    private let frames120 = Atomic<UInt64>(0)
    /// Main run-loop wakes (sleep to awake) since start; never reset (readers diff two reads).
    private let mainWakeCount = Atomic<UInt64>(0)
    private let gapMaxNanos = Atomic<UInt64>(0)
    static let frame120Nanos: UInt64 = 8_333_333
    let mainAsleep = Atomic<Bool>(true)
    /// A decided quit is ending (``endHangAssertions()``).
    private let assertionsEnded = Atomic<Bool>(false)
    let running = Atomic<Bool>(false)
    /// The watchdog thread's wait: the main thread arms it on each wake and deletes it before
    /// each sleep, so only a turn longer than `sampleAfterNanos` wakes the watchdog thread.
    private let alarm = MainThreadWatchdogAlarm()
    /// The stall sample, published by the watchdog thread while the main
    /// thread is still suspended (so a stall that ends right after the
    /// sample still finds it): the beat it belongs to, and its frame count
    /// in the sampler's buffer. Count first, then beat (release).
    private let publishedSampleBeat = Atomic<UInt64>(.max)
    private let publishedSampleCount = Atomic<Int>(0)
    /// The scheduler task that was running in that sample (``MainTaskBoard/runningPacked``), so the
    /// stall record names the culprit: packed identity, start and budget. Written while the main
    /// thread is suspended (atomics only).
    private let publishedTaskPacked = Atomic<UInt64>(0)
    private let publishedTaskStart = Atomic<UInt64>(0)
    private let publishedTaskBudget = Atomic<UInt64>(0)
    /// The main-thread scheduler's board (``attach(board:)``).
    let boardSink = Mutex<MainTaskBoard?>(nil)
    /// Stacks sampled while a scheduled task ran past its class budget, by packed task identity
    /// (the newest few), until the task ends and its over-budget record takes the stack.
    let taskSamples = Mutex<[(packed: UInt64, addresses: [UInt])]>([])
    /// Scheduled tasks that ran past their class's per-frame budget (``attach(board:)``): their own
    /// log, so a flood of them never pushes stalls out of ``log``.
    public let overBudget = HangLog(capacity: 128)
    private let sampler = Mutex<ThreadStackSampler?>(nil)
    /// Samples scheduled tasks past their budget: made only in the task diagnostics mode
    /// (``attach(board:recordTaskBudgets:)``), nil in every other launch.
    let taskSampler = Mutex<ThreadStackSampler?>(nil)
    /// Set once the task diagnostics mode is on (sampler and board installed): the watchdog loop
    /// reads this one atomic and takes no lock in every other launch.
    let taskDiagnostics = Atomic<Bool>(false)
    private let observer = Mutex<ObserverBox?>(nil)
    #if DEBUG
    /// Tests: runs on the watchdog thread right after a sample, to hold that
    /// thread past the end of a stall. Debug builds only: release builds
    /// carry no test seam.
    let afterSampleForTesting = Mutex<(@Sendable () -> Void)?>(nil)
    /// Tests: runs on the watchdog thread right before each wait (its limit in ns, nil for none),
    /// so a test can make a wake land between the thread's read of the board and its wait.
    let beforeWaitForTesting = Mutex<(@Sendable (UInt64?) -> Void)?>(nil)
    /// The heartbeat sequence (tests wait for it to move).
    var currentBeat: UInt64 { beatSequence.load(ordering: .acquiring) }
    /// Times the watchdog thread returned from a wait (tests count its idle wakeups).
    let watchdogWakes = Atomic<UInt64>(0)
    #endif
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, uptime: { MainThreadWatchdog.now() })
    }

    init(configuration: Configuration, uptime: @escaping @Sendable () -> UInt64) {
        self.configuration = configuration
        self.uptime = uptime
        self.log = HangLog(capacity: configuration.capacity)
        self.busy = BusyWatchdog(log: log)
        self.thresholdNanos = UInt64(clamping: max(configuration.threshold.wholeMilliseconds, 1)).saturatingMultiplication(1_000_000)
        self.sampleAfterNanos = thresholdNanos / 5 * 3 + thresholdNanos % 5 * 3 / 5
        self.hangNanos = Self.nanos(configuration.hangThreshold)
        self.hangIntervalNanos = Self.nanos(configuration.hangReportInterval)
        self.hangAssertNanos = configuration.hangAssertThreshold.map(Self.nanos)
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// How many times the main run loop woke from sleep since ``start()``, in the common modes the
    /// watchdog observes (a nested loop in another mode is not seen). Idle benches diff two reads
    /// (`debug.hangs` `main_wakes`): the budget for an idle app is 0 per second.
    public var mainRunLoopWakes: UInt64 { mainWakeCount.load(ordering: .relaxed) }

    /// Main-thread work gaps over 16.7 ms since the last reset, and the longest.
    public var longFrameStats: (count: Int, max: Duration) {
        (Int(clamping: longFrames.load(ordering: .relaxed)), .nanoseconds(Int64(clamping: longFrameMaxNanos.load(ordering: .relaxed))))
    }

    /// Main-thread work gaps over 8.3 ms since the last reset, and the
    /// longest gap of any length.
    public var gapStats: (over120HzFrame: Int, max: Duration) {
        (Int(clamping: frames120.load(ordering: .relaxed)), .nanoseconds(Int64(clamping: gapMaxNanos.load(ordering: .relaxed))))
    }

    /// A decided quit is ending: from now on a hang is still reported, but
    /// never fails the debug assertion. The quit's own deadline bounds it
    /// (`QuitDeadline`), so a debug build ends as a release one does.
    public func endHangAssertions() {
        assertionsEnded.store(true, ordering: .releasing)
    }

    public func resetLongFrames() {
        longFrames.store(0, ordering: .relaxed)
        longFrameMaxNanos.store(0, ordering: .relaxed)
        frames120.store(0, ordering: .relaxed)
        gapMaxNanos.store(0, ordering: .relaxed)
    }

    /// Starts watching the main run loop. Call once, on the main actor.
    @MainActor
    public func start() {
        guard running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        busy.watchCurrentThread()
        beatNanos.store(uptime(), ordering: .releasing)
        beatCPUNanos.store(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), ordering: .releasing)
        mainAsleep.store(false, ordering: .releasing)
        // Two observers: every activity but before-waiting stamps first
        // (order CFIndex.min); before-waiting stamps last (CFIndex.max), so
        // AppKit's layout, display and the Core Animation commit, which run
        // in before-waiting observers, count as main-thread work.
        let early = CFRunLoopActivity.allActivities.subtracting(.beforeWaiting).rawValue
        let earlyObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, early, true, CFIndex.min) { [weak self] _, activity in
            self?.heartbeat(activity)
        }
        // The late stamp draws nothing: its context says so to the commit-boundary audit.
        let lateObserver = MainRunLoopObserver.afterCommitObserver(activities: .beforeWaiting, order: CFIndex.max) { [weak self] activity in
            self?.heartbeat(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), earlyObserver, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), lateObserver, .commonModes)
        let box = ObserverBox([earlyObserver, lateObserver])
        observer.withLock { $0 = box }
        let sampler = configuration.sampleStacks ? ThreadStackSampler(thread: mach_thread_self()) : nil
        self.sampler.withLock { $0 = sampler }
        // Without its kqueue the thread could not wait: stalls are still measured on the main thread.
        guard alarm.isAvailable else {
            logger.error("main-thread watchdog: no kqueue; stalls are measured, not sampled")
            return
        }
        let thread = Thread { [self] in watch(sampler: sampler) }
        thread.name = "cmux-next main-thread watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// A scheduled task started (``MainTaskBoard`` hook, main thread): the watchdog thread
    /// re-reads when that task crosses its budget. One user-event trigger on the alarm's kqueue.
    func wakeForTask() {
        guard running.load(ordering: .relaxed) else { return }
        alarm.wake()
    }

    public func stop() {
        guard running.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged else { return }
        if let box = observer.withLock({ observer in defer { observer = nil }; return observer }) {
            for runLoopObserver in box.observers { CFRunLoopObserverInvalidate(runLoopObserver) }
        }
        alarm.wake()
    }

    // MARK: - Main thread

    /// One run-loop activity on the main thread (the observers call it;
    /// tests call it directly).
    func heartbeat(_ activity: CFRunLoopActivity) {
        let now = uptime()
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let previous = beatNanos.load(ordering: .acquiring)
        let wasAsleep = mainAsleep.load(ordering: .acquiring)
        let beat = beatSequence.load(ordering: .acquiring)
        if !wasAsleep, now > previous {
            let gap = now - previous
            Self.raise(gapMaxNanos, to: gap)
            if gap >= Self.frame120Nanos { frames120.add(1, ordering: .relaxed) }
            if gap >= Self.frameNanos {
                longFrames.add(1, ordering: .relaxed)
                Self.raise(longFrameMaxNanos, to: gap)
            }
        }
        if !wasAsleep, now > previous, now - previous >= thresholdNanos {
            let previousCPU = beatCPUNanos.load(ordering: .acquiring)
            recordStall(start: previous, nanos: now - previous, cpuNanos: cpu > previousCPU ? cpu - previousCPU : 0, beat: beat)
        }
        beatCPUNanos.store(cpu, ordering: .releasing)
        beatNanos.store(now, ordering: .releasing)
        beatSequence.store(beat &+ 1, ordering: .releasing)
        let asleep = activity == .beforeWaiting
        mainAsleep.store(asleep, ordering: .releasing)
        if wasAsleep, !asleep {
            mainWakeCount.add(1, ordering: .relaxed)
            busy.noteAwake()
            // The watchdog thread wakes only if this turn is still running when it is due to sample.
            alarm.arm(afterNanos: sampleAfterNanos)
        } else if asleep, !wasAsleep {
            alarm.disarm()
        }
    }

    private func recordStall(start: UInt64, nanos: UInt64, cpuNanos: UInt64, beat: UInt64) {
        var addresses: [UInt] = []
        var details: [String: JSONValue] = [:]
        if publishedSampleBeat.load(ordering: .acquiring) == beat, let sampler = sampler.withLock({ $0 }) {
            addresses = sampler.copy(count: publishedSampleCount.load(ordering: .relaxed))
            // The scheduled task the sample caught (none: AppKit's own work, the display cycle or the commit).
            if let board = boardSink.withLock({ $0 }),
               let task = board.task(packed: publishedTaskPacked.load(ordering: .relaxed),
                                     startNanos: publishedTaskStart.load(ordering: .relaxed),
                                     budgetNanos: publishedTaskBudget.load(ordering: .relaxed)) {
                details = Self.details(of: task)
                details["task_started_ms"] = .number((Double(task.startNanos) - Double(start)) / 1_000_000)
            }
        }
        let record = log.append(startUptimeNanos: start, duration: .nanoseconds(Int64(clamping: nanos)),
                                cpu: .nanoseconds(Int64(clamping: cpuNanos)), addresses: addresses, details: details)
        if configuration.logStalls {
            // No symbolication here (main thread); `debug.hangs` resolves the stack.
            logger.error("main thread stalled \(record.duration.fractionalMilliseconds, format: .fixed(precision: 1)) ms (hang \(record.sequence), \(addresses.count) frames; see debug.hangs)")
        }
        if nanos >= hangNanos { hangEnds.withLock { $0.append((beat, nanos, cpuNanos)); if $0.count > 4 { $0.removeFirst() } } }
        stallSink.withLock { $0 }?(record)
    }

    // MARK: - Watchdog thread

    func watch(sampler: ThreadStackSampler?) {
        var sampledBeat: UInt64 = .max
        var sampledTask: UInt64 = 0
        var hang = HangState(episodes: HangEpisodeTracker(hangNanos: hangNanos))
        while running.load(ordering: .acquiring) {
            closeRecoveredEpisode(&hang.episodes) // the beat moved while busy (also before the early waits)
            if mainAsleep.load(ordering: .acquiring) {
                closeRecoveredEpisode(&hang.episodes) // seen asleep: an open hang ended; before parking
                // Parked until a main turn outlasts the sample delay (its alarm) or stop(). A wake
                // between the check and the wait is not lost: the kernel keeps the fired timer.
                waitForAlarm(nanos: nil)
                continue
            }
            let beat = beatSequence.load(ordering: .acquiring)
            var due = beatNanos.load(ordering: .acquiring) &+ (beat == sampledBeat ? thresholdNanos : sampleAfterNanos)
            let now = uptime()
            // A scheduled task past its class budget gets one stack sample (attach(board:)).
            if let taskDue = sampleTaskOverBudget(now: now, sampled: &sampledTask) { due = min(due, taskDue) }
            if now < due {
                // Bounded wait until the next heartbeat check (or the main thread's next alarm).
                waitForAlarm(nanos: due - now)
                continue
            }
            // The heartbeat is old enough that the main thread may be stalling.
            if beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring), beat != sampledBeat {
                sampledBeat = beat
                // One syscall per sampled stall: the base of a hang's page-in count.
                stallEvents.withLock { $0 = (beat, TaskEventCounts.current()) }
                if let sampler {
                    let board = boardSink.withLock { $0 }
                    // Raw addresses only: symbolicating here can outlast a short stall.
                    // Published before the main thread resumes: atomics only in here.
                    _ = sampler.sample { count in
                        let task = board?.runningPacked ?? (packed: 0, startNanos: 0, budgetNanos: 0)
                        publishedTaskPacked.store(task.packed, ordering: .relaxed)
                        publishedTaskStart.store(task.startNanos, ordering: .relaxed)
                        publishedTaskBudget.store(task.budgetNanos, ordering: .relaxed)
                        publishedSampleCount.store(count, ordering: .relaxed)
                        publishedSampleBeat.store(beat, ordering: .releasing)
                    }
                    #if DEBUG
                    afterSampleForTesting.withLock { $0 }?()
                    #endif
                }
            }
            checkHang(beat: beat, sampler: sampler, state: &hang)
            // Check again one threshold later; once the turn ended the next pass parks.
            waitForAlarm(nanos: thresholdNanos)
        }
        if let event = hang.episodes.finish() { handle(event) } // stopped mid-hang: the duration so far
    }

    /// The watchdog thread's one wait (``MainThreadWatchdogAlarm/wait(nanos:)``); debug builds
    /// count each return (tests read the count).
    private func waitForAlarm(nanos: UInt64?) {
        #if DEBUG
        beforeWaitForTesting.withLock { $0 }?(nanos)
        #endif
        // concurrency-allow: the dedicated watchdog thread's kevent wait; never the main thread.
        alarm.wait(nanos: nanos)
        #if DEBUG
        watchdogWakes.add(1, ordering: .relaxed)
        #endif
    }

    /// The watchdog thread's hang bookkeeping.
    private struct HangState {
        var episodes: HangEpisodeTracker
        var assertedBeat: UInt64 = .max
        var lastReportNanos: UInt64?
    }

    /// Reports a stall that has lasted `hangThreshold` (once per stall, at
    /// most once per `hangReportInterval`), and in debug builds fails an
    /// assertion past `hangAssertThreshold`. Watchdog thread only.
    private func checkHang(beat: UInt64, sampler: ThreadStackSampler?, state: inout HangState) {
        guard beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring) else { return }
        let now = uptime()
        let started = beatNanos.load(ordering: .acquiring)
        guard now > started else { return }
        let elapsed = now - started
        for event in state.episodes.observe(beat: beat, busy: true, elapsedNanos: elapsed) {
            if case .began = event {
                reportHang(beat: beat, elapsedNanos: elapsed, now: now, sampler: sampler, lastReportNanos: &state.lastReportNanos)
            } else {
                handle(event)
            }
        }
        if let hangAssertNanos, elapsed >= hangAssertNanos, state.assertedBeat != beat,
           !assertionsEnded.load(ordering: .acquiring),
           Self.hangFailsAssertion(elapsedNanos: elapsed, mainThreadCPUNanos: mainThreadCPU(sinceBeat: beat),
                                   assertNanos: hangAssertNanos) {
            state.assertedBeat = beat
            assertionFailure("main thread hang: busy over \(configuration.hangAssertThreshold ?? .zero); see debug.hangs and the crash report")
        }
    }

    /// Main-thread CPU used since heartbeat `beat` began the stall (its
    /// `beatCPUNanos` stamp); nil when the reading failed or `beat` ended.
    func mainThreadCPU(sinceBeat beat: UInt64) -> UInt64? {
        let start = beatCPUNanos.load(ordering: .acquiring)
        guard beatSequence.load(ordering: .acquiring) == beat, let now = busy.mainThreadCPUNanos() else { return nil }
        return now > start ? now - start : 0
    }

    private static func nanos(_ duration: Duration) -> UInt64 {
        UInt64(clamping: max(duration.wholeMilliseconds, 1)).saturatingMultiplication(1_000_000)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func raise(_ value: borrowing Atomic<UInt64>, to candidate: UInt64) {
        var current = value.load(ordering: .relaxed)
        while candidate > current {
            let (exchanged, original) = value.compareExchange(expected: current, desired: candidate, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    /// CFRunLoopObserver is thread-safe to invalidate from any thread.
    private final class ObserverBox: @unchecked Sendable {
        let observers: [CFRunLoopObserver]
        init(_ observers: [CFRunLoopObserver?]) { self.observers = observers.compactMap { $0 } }
    }
}

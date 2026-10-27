import CoreFoundation
import Darwin
import Foundation
import os
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextTrace
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
        /// At most one hang report per this interval (default 5 min).
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

        /// The debug assertion is useful for interactive launches, but an
        /// isolated diagnostic or bench launch (``LaunchIsolation/isolated``)
        /// must stay alive long enough to preserve its watchdog evidence after
        /// reporting a hang.
        public static var defaultHangAssertThreshold: Duration? {
            hangAssertThreshold(debugBuild: ControlService.isDebugBuild,
                                isolatedLaunch: LaunchIsolation(environment: ProcessInfo.processInfo.environment).isolated)
        }

        /// Policy seam kept explicit so diagnostic-launch behavior is tested
        /// without mutating the process environment.
        public static func hangAssertThreshold(debugBuild: Bool, isolatedLaunch: Bool) -> Duration? {
            debugBuild && !isolatedLaunch ? .seconds(10) : nil
        }

        public init(threshold: Duration = Configuration.environmentThreshold, capacity: Int = 128, sampleStacks: Bool = true,
                    logStalls: Bool = ControlService.isDebugBuild, hangThreshold: Duration = .seconds(2),
                    hangReportInterval: Duration = .seconds(300),
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
    let mainTurnMinimumNanos = Atomic<UInt64>(.max), turnStartNanos = Atomic<UInt64>(0) // +MainTurns
    let mainTurnSink = Mutex<(@Sendable (UInt64, UInt64) -> Void)?>(nil)
    let fieldMetrics: MainThreadFieldMetrics // main.turn and hang.over250.per_hour (+MainTurns, MainTurnHistogram)
    public let turnHistogram = MainTurnHistogram(), inputQueueHistogram = MainTurnHistogram() // +MainTurns, MainTurnHistogram
    /// The newest input event time counted in ``inputQueueHistogram`` (ns of uptime; main thread writes): a re-sent event is no newer.
    let newestQueuedInputNanos = Atomic<UInt64>(0)
    let episodeSink = Mutex<HangEpisodeRecorder?>(nil) // ``episodes``
    /// Finished stalls of a hang's length by beat, the newest few, until their file takes one (+Episodes).
    let hangEnds = Mutex<[(beat: UInt64, nanos: UInt64)]>([])
    private let hangNanos: UInt64
    let hangIntervalNanos: UInt64
    private let hangAssertNanos: UInt64?
    public let log: HangLog
    /// Busy windows (CPU with no input, animation or output) share the log.
    public let busy: BusyWatchdog
    /// Hang-watch scopes on other threads still open 2 s past their budget (``attach(hangWatch:crashKeys:trace:)``,
    /// kind `hang`, with a stack): their own log, so a lane that hangs again and again never pushes
    /// main-thread stalls out of ``log``.
    public let threadHangs = HangLog(capacity: 128)
    /// Hang-watch scopes on other threads past their budget (kind `jank`, no stack): apart from
    /// ``threadHangs``, so a busy lane's janks never push the rarer hang dumps out.
    public let threadJanks = HangLog(capacity: 128)
    /// What ``attach(hangWatch:crashKeys:trace:)`` connected (read once, after the flag), and the sinks of ``onThreadHang`` and ``onLastHang`` (HangMonitor.swift).
    let hangWatchSink = Mutex<HangMonitor.Source?>(nil), threadHangSinks = Mutex(ThreadHangSinks())
    let hangWatchAttached = Atomic<Bool>(false)
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
    /// Work gaps of 100 ms and up (low 32 bits) and of 250 ms and up (high 32 bits) (``StallCounts``), counted on
    /// the main thread. One word, so one add counts a gap in both and a read or a reset is never half done.
    private let stallPair = Atomic<UInt64>(0)
    static let stallPair100: UInt64 = 1, stallPair250: UInt64 = 1 | 1 << 32
    static let count100Nanos = nanos(StallCounts.edge100), count250Nanos = nanos(StallCounts.edge250)
    let mainAsleep = Atomic<Bool>(true)
    /// A decided quit is ending (``endHangAssertions()``).
    private let assertionsEnded = Atomic<Bool>(false)
    let running = Atomic<Bool>(false)
    /// Set by the first ``start()``: the watchdog runs once, so a stop and a start never leave two threads.
    private let startedOnce = Atomic<Bool>(false)
    /// The watchdog thread's wait: the main thread arms it on each wake and deletes it before
    /// each sleep, so only a turn longer than `sampleAfterNanos` wakes the watchdog thread.
    let alarm = MainThreadWatchdogAlarm()
    /// The stall sample, published by the watchdog thread while the main
    /// thread is still suspended (so a stall that ends right after the
    /// sample still finds it): the beat it belongs to, and its frame count
    /// in the sampler's buffer. Count first, then beat (release).
    private let publishedSampleBeat = Atomic<UInt64>(.max), publishedSampleCount = Atomic<Int>(0)
    /// The scheduler task that was running in that sample (``MainTaskBoard/runningPacked``), so the
    /// stall record names the culprit: packed identity, start and budget. Written while the main
    /// thread is suspended (atomics only).
    private let publishedTaskPacked = Atomic<UInt64>(0)
    private let publishedTaskStart = Atomic<UInt64>(0)
    private let publishedTaskBudget = Atomic<UInt64>(0)
    private let publishedCEFState = Atomic<UInt64>(0) // the crash keys' CEF state in it (phaseLabel(cefState:))
    /// The main-thread scheduler's board (``attach(board:)``).
    let boardSink = Mutex<MainTaskBoard?>(nil)
    /// Stacks sampled while a scheduled task ran past its class budget, by packed task identity
    /// (the newest few), until the task ends and its over-budget record takes the stack.
    let taskSamples = Mutex<[(packed: UInt64, addresses: [UInt])]>([])
    /// Scheduled tasks that ran past their class's per-frame budget (``attach(board:)``), and those past
    /// their class's hang deadline (``taskHangs``, +HangScopes): logs of their own, so neither pushes stalls out of ``log``.
    public let overBudget = HangLog(capacity: 128), taskHangs = HangLog(capacity: 128)
    private let sampler = Mutex<ThreadStackSampler?>(nil)
    /// Samples scheduled tasks past their hang deadline and, in the task diagnostics mode, past their
    /// budget (``attach(board:recordTaskBudgets:)``); nil before a board is attached or without stacks.
    let taskSampler = Mutex<ThreadStackSampler?>(nil)
    /// Set once the task diagnostics mode is on (sampler and board installed): the watchdog loop
    /// reads this one atomic and takes no lock in every other launch.
    let taskDiagnostics = Atomic<Bool>(false)
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
    /// Tests: the run-loop observers still on the main run loop. Its own object, so a test reads it
    /// after the watchdog is gone.
    let observersForTesting = ObserverCountForTesting()
    final class ObserverCountForTesting: Sendable {
        let live = Atomic<Int>(0)
    }
    #endif
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, uptime: { MainThreadWatchdog.now() })
    }

    init(configuration: Configuration, uptime: @escaping @Sendable () -> UInt64, fieldMetrics: MainThreadFieldMetrics = MainThreadFieldMetrics()) {
        self.configuration = configuration
        self.fieldMetrics = fieldMetrics
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

    /// Main-thread work gaps of 100 ms and up and of 250 ms and up since ``start()`` or the last
    /// ``resetStallCounts()``, whatever the stall threshold (`debug.hangs` `count100` and `count250`).
    public var stallCounts: StallCounts {
        let pair = stallPair.load(ordering: .relaxed)
        return StallCounts(count100: Int(clamping: pair & 0xFFFF_FFFF), count250: Int(clamping: pair >> 32))
    }

    public func resetStallCounts() {
        stallPair.store(0, ordering: .relaxed)
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

    /// Starts watching the main run loop. Call once, on the main actor: a start after ``stop()`` does nothing.
    @MainActor
    public func start() {
        guard startedOnce.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged,
              running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        busy.watchCurrentThread()
        let started = uptime()
        beatNanos.store(started, ordering: .releasing)
        // The turn this call runs in is awake (mainAsleep false below) and began no later than now.
        turnStartNanos.store(started, ordering: .relaxed)
        beatCPUNanos.store(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), ordering: .releasing)
        mainAsleep.store(false, ordering: .releasing)
        // Two observers: every activity but before-waiting stamps first
        // (order CFIndex.min); before-waiting stamps last (lastOrder), so
        // AppKit's layout, display and the Core Animation commit, which run
        // in before-waiting observers, count as main-thread work.
        // Each observer removes itself on the main thread at its first call after ``stop()`` (or after the
        // watchdog is gone), so no other thread ever holds or invalidates it.
        #if DEBUG
        let observerCount = observersForTesting
        #endif
        let beat: (CFRunLoopObserver?, CFRunLoopActivity) -> Void = { [weak self] observer, activity in
            guard let self, running.load(ordering: .acquiring) else {
                guard let observer, CFRunLoopObserverIsValid(observer) else { return }
                CFRunLoopObserverInvalidate(observer)
                #if DEBUG
                observerCount.live.subtract(1, ordering: .relaxed)
                #endif
                return
            }
            heartbeat(activity)
        }
        let early = CFRunLoopActivity.allActivities.subtracting(.beforeWaiting).rawValue
        let earlyObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, early, true, CFIndex.min, beat)
        let lateObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true,
                                                              MainRunLoopObserver.lastOrder, beat)
        CFRunLoopAddObserver(CFRunLoopGetMain(), earlyObserver, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), lateObserver, .commonModes)
        #if DEBUG
        observerCount.live.add(2, ordering: .relaxed)
        #endif
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
        hangWatchSink.withLock { $0 }?.watch.detachMonitor()
        guard running.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged else { return }
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
            if gap >= Self.count250Nanos {
                stallPair.wrappingAdd(Self.stallPair250, ordering: .relaxed)
                fieldMetrics.stallOver250Ended(start: previous)
            } else if gap >= Self.count100Nanos {
                stallPair.wrappingAdd(Self.stallPair100, ordering: .relaxed)
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
            turnStartNanos.store(now, ordering: .relaxed)
            // The watchdog thread wakes only if this turn is still running when it is due to sample.
            alarm.arm(afterNanos: sampleAfterNanos)
        } else if asleep, !wasAsleep {
            alarm.disarm()
            mainTurnEnded(start: turnStartNanos.load(ordering: .relaxed), end: now)
        }
    }

    private func recordStall(start: UInt64, nanos: UInt64, cpuNanos: UInt64, beat: UInt64) {
        var addresses: [UInt] = []
        var details: [String: JSONValue] = [:]
        if publishedSampleBeat.load(ordering: .acquiring) == beat, let sampler = sampler.withLock({ $0 }) {
            addresses = sampler.copy(count: publishedSampleCount.load(ordering: .relaxed))
            // The scheduled task the sample caught, or `unattributed` (AppKit's own work, the display cycle or the commit).
            if let board = boardSink.withLock({ $0 }) {
                let task = board.task(packed: publishedTaskPacked.load(ordering: .relaxed), startNanos: publishedTaskStart.load(ordering: .relaxed),
                                      budgetNanos: publishedTaskBudget.load(ordering: .relaxed))
                details = task.map(Self.details(of:)) ?? HangAttribution(task: nil, turnNanos: nanos).details
                if let task { details["task_started_ms"] = .number((Double(task.startNanos) - Double(start)) / 1_000_000) }
            }
            if let phase = Self.phaseLabel(cefState: publishedCEFState.load(ordering: .relaxed)) { details["phase"] = .string(phase) }
        }
        let record = log.append(startUptimeNanos: start, duration: .nanoseconds(Int64(clamping: nanos)),
                                cpu: .nanoseconds(Int64(clamping: cpuNanos)), addresses: addresses, details: details)
        if configuration.logStalls {
            // No symbolication here (main thread); `debug.hangs` resolves the stack.
            logger.error("main thread stalled \(record.duration.fractionalMilliseconds, format: .fixed(precision: 1)) ms (hang \(record.sequence), \(addresses.count) frames; see debug.hangs)")
        }
        if nanos >= hangNanos { hangEnds.withLock { ends in ends.append((beat, nanos)); if ends.count > 4 { ends.removeFirst() } } }
        stallSink.withLock { $0 }?(record)
    }

    // MARK: - Watchdog thread

    func watch(sampler: ThreadStackSampler?) {
        var sampledBeat: UInt64 = .max
        var sampledTask: UInt64 = 0, reportedScope: UInt64 = 0
        var hang = HangState(episodes: HangEpisodeTracker(hangNanos: hangNanos))
        var threadHangs: HangMonitor?
        var waitOverrun: UInt64 = 0
        while running.load(ordering: .acquiring) {
            if threadHangs == nil { threadHangs = hangMonitor() }
            // Other threads' hang-watch scopes: a scan when one is due, and the wait until the next.
            let hangWait = threadHangs?.service(waitOverrunNanos: waitOverrun)
            closeRecoveredEpisode(&hang.episodes) // the beat moved while busy (also before the early waits)
            if mainAsleep.load(ordering: .acquiring) {
                closeRecoveredEpisode(&hang.episodes) // seen asleep: an open hang ended; before parking
                // Parked until a main turn outlasts the sample delay (its alarm), a hang-watch scan is
                // due, a scope wakes it, or stop(). A wake between the check and the wait is not lost:
                // the kernel keeps the fired timer and the triggered user event.
                waitOverrun = waitForAlarm(nanos: hangWait)
                continue
            }
            let beat = beatSequence.load(ordering: .acquiring)
            var due = beatNanos.load(ordering: .acquiring) &+ (beat == sampledBeat ? thresholdNanos : sampleAfterNanos)
            let now = uptime()
            // A scheduled task past its class budget or its hang deadline gets one stack sample (attach(board:)).
            if let taskDue = checkRunningTask(now: now, sampled: &sampledTask, reported: &reportedScope) { due = min(due, taskDue) }
            if now < due {
                // Bounded wait until the next heartbeat check (or the main thread's next alarm).
                waitOverrun = waitForAlarm(nanos: Self.sooner(due - now, hangWait))
                continue
            }
            // The heartbeat is old enough that the main thread may be stalling.
            if beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring), beat != sampledBeat {
                sampledBeat = beat
                if let sampler {
                    let board = boardSink.withLock { $0 }, crashKeys = threadHangs?.crashKeys
                    // Raw addresses only: symbolicating here can outlast a short stall.
                    // Published before the main thread resumes: atomics only in here.
                    _ = sampler.sample { count in
                        publishedCEFState.store(crashKeys?.value(.cefState) ?? 0, ordering: .relaxed)
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
            checkHang(beat: beat, sampler: sampler, crashKeys: threadHangs?.crashKeys, state: &hang)
            // Check again one threshold later; once the turn ended the next pass parks.
            waitOverrun = waitForAlarm(nanos: Self.sooner(thresholdNanos, hangWait))
        }
        if let event = hang.episodes.finish() { handle(event) } // stopped mid-hang: the duration so far
    }

    /// The watchdog thread's one wait (``MainThreadWatchdogAlarm/wait(nanos:)``); debug builds
    /// count each return (tests read the count).
    ///
    /// - Returns: How far the wait ran past its timeout (0 with no timeout): the thread's own drift, which the
    ///   hang monitor tolerates up to 100 ms (``HangMonitor/service(waitOverrunNanos:)``).
    private func waitForAlarm(nanos: UInt64?) -> UInt64 {
        #if DEBUG
        beforeWaitForTesting.withLock { $0 }?(nanos)
        #endif
        let before = Self.now() // the kernel's timeout runs on the real clock, so the wait is timed on it too
        // concurrency-allow: the dedicated watchdog thread's kevent wait; never the main thread.
        alarm.wait(nanos: nanos)
        let after = Self.now()
        #if DEBUG
        watchdogWakes.add(1, ordering: .relaxed)
        #endif
        guard let nanos, after > before, after - before > nanos else { return 0 }
        return after - before - nanos
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
    private func checkHang(beat: UInt64, sampler: ThreadStackSampler?, crashKeys: CrashKeySlots?, state: inout HangState) {
        guard beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring) else { return }
        let now = uptime()
        let started = beatNanos.load(ordering: .acquiring)
        guard now > started else { return }
        let elapsed = now - started
        for event in state.episodes.observe(beat: beat, busy: true, elapsedNanos: elapsed) {
            if case .began = event {
                fieldMetrics.threadHung(.main, atNanos: started)
                reportHang(beat: beat, elapsedNanos: elapsed, now: now, sampler: sampler, crashKeys: crashKeys, lastReportNanos: &state.lastReportNanos)
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
    private func mainThreadCPU(sinceBeat beat: UInt64) -> UInt64? {
        let start = beatCPUNanos.load(ordering: .acquiring)
        guard beatSequence.load(ordering: .acquiring) == beat, let now = busy.mainThreadCPUNanos() else { return nil }
        return now > start ? now - start : 0
    }

    private static func nanos(_ duration: Duration) -> UInt64 {
        UInt64(clamping: max(duration.wholeMilliseconds, 1)).saturatingMultiplication(1_000_000)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// The shorter of a wait and an optional one (nil: no limit).
    private static func sooner(_ nanos: UInt64, _ other: UInt64?) -> UInt64 { other.map { min(nanos, $0) } ?? nanos }

    private static func raise(_ value: borrowing Atomic<UInt64>, to candidate: UInt64) {
        var current = value.load(ordering: .relaxed)
        while candidate > current {
            let (exchanged, original) = value.compareExchange(expected: current, desired: candidate, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }
}

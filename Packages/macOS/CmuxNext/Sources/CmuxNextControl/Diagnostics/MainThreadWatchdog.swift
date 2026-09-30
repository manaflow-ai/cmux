import CoreFoundation
import Darwin
import Foundation
import os
import Synchronization

/// Records every main-thread stall longer than `threshold` (default 50 ms)
/// with a stack sample, into a ring buffer (`debug.hangs`).
///
/// A `CFRunLoopObserver` on the main run loop stamps a heartbeat at every
/// run-loop activity. Time between two stamps while the loop is not asleep
/// is main-thread work; a gap over the threshold is a stall, measured
/// exactly on the main thread when it ends. A dedicated watchdog thread
/// parks while the main run loop sleeps (no wakeups when the app is idle),
/// and while it is awake checks once per threshold whether the heartbeat
/// stopped; if so it samples the main thread's stack mid-stall.
public final class MainThreadWatchdog: Sendable {
    public struct Configuration: Sendable {
        public var threshold: Duration
        public var capacity: Int
        public var sampleStacks: Bool
        public var logStalls: Bool

        /// `CMUX_NEXT_HANG_THRESHOLD_MS` lowers the threshold for a
        /// diagnostic launch (for example 8 to sample one-frame stalls);
        /// the default is 50 ms.
        public static var environmentThreshold: Duration {
            let raw = ProcessInfo.processInfo.environment["CMUX_NEXT_HANG_THRESHOLD_MS"].flatMap(Int.init) ?? 50
            return .milliseconds(min(max(raw, 4), 1_000))
        }

        public init(threshold: Duration = Configuration.environmentThreshold, capacity: Int = 128, sampleStacks: Bool = true,
                    logStalls: Bool = ControlService.isDebugBuild) {
            self.threshold = threshold
            self.capacity = capacity
            self.sampleStacks = sampleStacks
            self.logStalls = logStalls
        }
    }

    public let configuration: Configuration
    public let log: HangLog
    /// Busy windows (CPU with no input, animation or output) share the log.
    public let busy: BusyWatchdog
    private let thresholdNanos: UInt64
    /// The stack is sampled this long into a stall (60% of the threshold),
    /// so a stall that ends just past the threshold still has one; the
    /// sample is dropped when the stall ends below the threshold.
    private let sampleAfterNanos: UInt64
    // Heartbeat, written by the main-thread observer.
    private let beatNanos = Atomic<UInt64>(0)
    private let beatSequence = Atomic<UInt64>(0)
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
    private let gapMaxNanos = Atomic<UInt64>(0)
    static let frame120Nanos: UInt64 = 8_333_333
    private let mainAsleep = Atomic<Bool>(true)
    private let watchdogParked = Atomic<Bool>(false)
    private let running = Atomic<Bool>(false)
    // concurrency-allow: only the watchdog thread waits on it; the main thread only signals.
    private let wake = DispatchSemaphore(value: 0)
    /// The stack sampled during the current stall, keyed by beat sequence.
    private let pendingSample = Mutex<(beat: UInt64, addresses: [UInt])?>(nil)
    private let observer = Mutex<ObserverBox?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.log = HangLog(capacity: configuration.capacity)
        self.busy = BusyWatchdog(log: log)
        self.thresholdNanos = UInt64(max(configuration.threshold.wholeMilliseconds, 1)) * 1_000_000
        self.sampleAfterNanos = thresholdNanos * 3 / 5
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// Main-thread work gaps over 16.7 ms since the last reset, and the longest.
    public var longFrameStats: (count: Int, max: Duration) {
        (Int(longFrames.load(ordering: .relaxed)), .nanoseconds(Int64(longFrameMaxNanos.load(ordering: .relaxed))))
    }

    /// Main-thread work gaps over 8.3 ms since the last reset, and the
    /// longest gap of any length.
    public var gapStats: (over120HzFrame: Int, max: Duration) {
        (Int(frames120.load(ordering: .relaxed)), .nanoseconds(Int64(gapMaxNanos.load(ordering: .relaxed))))
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
        beatNanos.store(Self.now(), ordering: .releasing)
        beatCPUNanos.store(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), ordering: .releasing)
        mainAsleep.store(false, ordering: .releasing)
        let activities = CFRunLoopActivity.allActivities.rawValue
        let runLoopObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, CFIndex.min) { [weak self] _, activity in
            self?.heartbeat(activity)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
        let box = ObserverBox(runLoopObserver)
        observer.withLock { $0 = box }
        let sampler = configuration.sampleStacks ? ThreadStackSampler(thread: mach_thread_self()) : nil
        let thread = Thread { [self] in watch(sampler: sampler) }
        thread.name = "cmux-next main-thread watchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func stop() {
        guard running.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged else { return }
        if let box = observer.withLock({ observer in defer { observer = nil }; return observer }) {
            CFRunLoopObserverInvalidate(box.observer)
        }
        wake.signal()
    }

    // MARK: - Main thread

    private func heartbeat(_ activity: CFRunLoopActivity) {
        let now = Self.now()
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
        if wasAsleep, !asleep { busy.noteAwake() }
        if !asleep, watchdogParked.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged {
            wake.signal()
        }
    }

    private func recordStall(start: UInt64, nanos: UInt64, cpuNanos: UInt64, beat: UInt64) {
        let addresses = pendingSample.withLock { sample -> [UInt] in
            defer { sample = nil }
            guard let sample, sample.beat == beat else { return [] }
            return sample.addresses
        }
        let record = log.append(startUptimeNanos: start, duration: .nanoseconds(Int64(nanos)),
                                cpu: .nanoseconds(Int64(cpuNanos)), addresses: addresses)
        if configuration.logStalls {
            // No symbolication here (main thread); `debug.hangs` resolves the stack.
            logger.error("main thread stalled \(record.duration.fractionalMilliseconds, format: .fixed(precision: 1)) ms (hang \(record.sequence), \(addresses.count) frames; see debug.hangs)")
        }
    }

    // MARK: - Watchdog thread

    private func watch(sampler: ThreadStackSampler?) {
        var sampledBeat: UInt64 = .max
        while running.load(ordering: .acquiring) {
            if mainAsleep.load(ordering: .acquiring) {
                watchdogParked.store(true, ordering: .releasing)
                // Re-check after publishing `parked`: the main thread may have woken in between.
                if !mainAsleep.load(ordering: .acquiring),
                   watchdogParked.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged {
                    continue
                }
                // concurrency-allow: dedicated watchdog thread parks while the main run loop sleeps; never the main thread.
                wake.wait()
                continue
            }
            let beat = beatSequence.load(ordering: .acquiring)
            let due = beatNanos.load(ordering: .acquiring) &+ (beat == sampledBeat ? thresholdNanos : sampleAfterNanos)
            let now = Self.now()
            if now < due {
                // concurrency-allow: dedicated watchdog thread; bounded wait until the next heartbeat check.
                _ = wake.wait(timeout: .now() + .nanoseconds(Int(due - now)))
                continue
            }
            // The heartbeat is old enough that the main thread may be stalling.
            if beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring), beat != sampledBeat {
                sampledBeat = beat
                if let sampler {
                    // Raw addresses only: symbolicating here can outlast a short stall.
                    let addresses = sampler.sample()
                    pendingSample.withLock { $0 = (beat, addresses) }
                }
            }
            // Check again one threshold later (or when the stall ends and the loop sleeps).
            // concurrency-allow: dedicated watchdog thread; bounded wait between stall checks.
            _ = wake.wait(timeout: .now() + .nanoseconds(Int(thresholdNanos)))
        }
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
        let observer: CFRunLoopObserver?
        init(_ observer: CFRunLoopObserver?) { self.observer = observer }
    }
}

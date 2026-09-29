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

        public init(threshold: Duration = .milliseconds(50), capacity: Int = 128, sampleStacks: Bool = true,
                    logStalls: Bool = ControlService.isDebugBuild) {
            self.threshold = threshold
            self.capacity = capacity
            self.sampleStacks = sampleStacks
            self.logStalls = logStalls
        }
    }

    public let configuration: Configuration
    public let log: HangLog
    private let thresholdNanos: UInt64
    // Heartbeat, written by the main-thread observer.
    private let beatNanos = Atomic<UInt64>(0)
    private let beatSequence = Atomic<UInt64>(0)
    private let mainAsleep = Atomic<Bool>(true)
    private let watchdogParked = Atomic<Bool>(false)
    private let running = Atomic<Bool>(false)
    // concurrency-allow: only the watchdog thread waits on it; the main thread only signals.
    private let wake = DispatchSemaphore(value: 0)
    /// The stack sampled during the current stall, keyed by beat sequence.
    private let pendingSample = Mutex<(beat: UInt64, frames: [HangFrame])?>(nil)
    private let observer = Mutex<ObserverBox?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "hangs")

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.log = HangLog(capacity: configuration.capacity)
        self.thresholdNanos = UInt64(max(configuration.threshold.wholeMilliseconds, 1)) * 1_000_000
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// Starts watching the main run loop. Call once, on the main actor.
    @MainActor
    public func start() {
        guard running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        beatNanos.store(Self.now(), ordering: .releasing)
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
        let previous = beatNanos.load(ordering: .acquiring)
        let wasAsleep = mainAsleep.load(ordering: .acquiring)
        let beat = beatSequence.load(ordering: .acquiring)
        if !wasAsleep, now > previous, now - previous >= thresholdNanos {
            recordStall(start: previous, nanos: now - previous, beat: beat)
        }
        beatNanos.store(now, ordering: .releasing)
        beatSequence.store(beat &+ 1, ordering: .releasing)
        let asleep = activity == .beforeWaiting
        mainAsleep.store(asleep, ordering: .releasing)
        if !asleep, watchdogParked.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged {
            wake.signal()
        }
    }

    private func recordStall(start: UInt64, nanos: UInt64, beat: UInt64) {
        let frames = pendingSample.withLock { sample -> [HangFrame] in
            defer { sample = nil }
            guard let sample, sample.beat == beat else { return [] }
            return sample.frames
        }
        let record = log.append(startUptimeNanos: start, duration: .nanoseconds(Int64(nanos)), frames: frames)
        if configuration.logStalls {
            let top = frames.prefix(12).map(\.description).joined(separator: " | ")
            logger.error("main thread stalled \(record.duration.fractionalMilliseconds, format: .fixed(precision: 1)) ms: \(top, privacy: .public)")
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
            let due = beatNanos.load(ordering: .acquiring) &+ thresholdNanos
            let now = Self.now()
            if now < due {
                // concurrency-allow: dedicated watchdog thread; bounded wait until the next heartbeat check.
                _ = wake.wait(timeout: .now() + .nanoseconds(Int(due - now)))
                continue
            }
            // The heartbeat is at least one threshold old: the main thread is stalled.
            if beat == beatSequence.load(ordering: .acquiring), !mainAsleep.load(ordering: .acquiring), beat != sampledBeat {
                sampledBeat = beat
                if let sampler {
                    let frames = ThreadStackSampler.symbolicate(sampler.sample())
                    if beat == beatSequence.load(ordering: .acquiring) {
                        pendingSample.withLock { $0 = (beat, frames) }
                    }
                }
            }
            // Check again one threshold later (or when the stall ends and the loop sleeps).
            // concurrency-allow: dedicated watchdog thread; bounded wait between stall checks.
            _ = wake.wait(timeout: .now() + .nanoseconds(Int(thresholdNanos)))
        }
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// CFRunLoopObserver is thread-safe to invalidate from any thread.
    private final class ObserverBox: @unchecked Sendable {
        let observer: CFRunLoopObserver?
        init(_ observer: CFRunLoopObserver?) { self.observer = observer }
    }
}

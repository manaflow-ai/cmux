import CoreFoundation
import Darwin
import Foundation
import os
import Synchronization

/// Watches the main run loop for turns that do not end: the iPhone app's port of the Mac's
/// `MainThreadWatchdog` (CmuxNextControl), kept to what a phone needs.
///
/// - Two run-loop observers stamp a heartbeat at every turn edge: every activity but
///   before-waiting first (order `CFIndex.min`), before-waiting last (`CFIndex.max`), so
///   SwiftUI's layout and the Core Animation commit count as main-thread work.
/// - A dedicated thread parks on a kqueue one-shot timer (``HangWatchdogAlarm``) that the main
///   thread arms when its loop wakes and deletes before it sleeps. A short turn wakes no other
///   thread; an idle app wakes the watchdog 0 times.
/// - A turn past ``Configuration/threshold`` is a stall: the main thread's stack is sampled once
///   (thread_suspend and a frame-pointer walk, raw addresses; symbolication happens off the
///   hot path), and the stall is kept in ``recentStalls()`` and sent to ``onStall``.
/// - A stall past ``Configuration/hangThreshold`` (2 s) is a hang: the stack is sampled again
///   and ``onHang`` runs on the watchdog thread when the hang begins and again when it ends.
///
/// It never traps, exits or kills the app (https://github.com/manaflow-ai/cmux/issues/50992):
/// it measures and reports, nothing more.
public final class MainThreadHangWatchdog: Sendable {
    public struct Configuration: Sendable {
        /// A main-thread turn this long is a stall (sampled once, kept, logged).
        public var threshold: Duration
        /// A stall this long is a hang (hang file, telemetry).
        public var hangThreshold: Duration
        /// Off: stalls and hangs are timed but carry no stack.
        public var sampleStacks: Bool
        /// How many stalls ``recentStalls()`` keeps (oldest dropped).
        public var capacity: Int

        public init(threshold: Duration = .milliseconds(100), hangThreshold: Duration = .seconds(2),
                    sampleStacks: Bool = true, capacity: Int = 32) {
            self.threshold = threshold
            self.hangThreshold = hangThreshold
            self.sampleStacks = sampleStacks
            self.capacity = capacity
        }
    }

    /// One main-thread turn past the threshold.
    public struct Stall: Sendable, Equatable {
        /// `CLOCK_UPTIME_RAW` nanoseconds when the turn began.
        public var startUptimeNanos: UInt64
        public var duration: Duration
        /// Return addresses, innermost first; empty when no sample was taken.
        public var addresses: [UInt]
    }

    /// A turn past the hang threshold: reported once when it begins (`ended` false, the
    /// duration so far) and once when it ends (`ended` true, the whole duration).
    public struct Hang: Sendable, Equatable {
        public var startUptimeNanos: UInt64
        public var duration: Duration
        /// The main thread's stack once the hang threshold passed.
        public var addresses: [UInt]
        public var ended: Bool
    }

    public let configuration: Configuration
    let thresholdNanos: UInt64
    /// The first sample is taken at 60% of the threshold, so a stall has its stack by the time
    /// it counts as one.
    let sampleAfterNanos: UInt64
    let hangNanos: UInt64
    let uptime: @Sendable () -> UInt64
    let alarm = HangWatchdogAlarm()
    let logger = Logger(subsystem: "dev.cmux.mobile", category: "hangs")

    // Heartbeat: written by the watched thread's observers.
    let beatNanos = Atomic<UInt64>(0)
    let beatSequence = Atomic<UInt64>(0)
    /// True while the watched run loop sleeps (and before ``start()``).
    let mainAsleep = Atomic<Bool>(true)
    let running = Atomic<Bool>(false)
    /// The beat the sampler's buffer belongs to, and its frame count.
    private let publishedSampleBeat = Atomic<UInt64>(.max)
    private let publishedSampleCount = Atomic<Int>(0)
    /// The last hang the watched thread saw end: its start and length (the watchdog thread
    /// reads them to report the hang's whole duration).
    private let endedHang = Mutex<(start: UInt64, nanos: UInt64)?>(nil)
    private let stalls = Mutex<[Stall]>([])
    private let sampler = Mutex<ThreadStackSampler?>(nil)
    private let observers = Mutex<ObserverBox?>(nil)
    private let stallSink = Mutex<(@Sendable (Stall) -> Void)?>(nil)
    private let hangSink = Mutex<(@Sendable (Hang) -> Void)?>(nil)
    #if DEBUG
    /// Runs on the watchdog thread right after a stall sample (tests).
    let afterSampleForTesting = Mutex<(@Sendable () -> Void)?>(nil)
    /// Every return from the watchdog thread's wait (the idle-wakeups test).
    let watchdogWakes = Atomic<UInt64>(0)
    #endif

    public convenience init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, uptime: { MainThreadHangWatchdog.now() })
    }

    init(configuration: Configuration, uptime: @escaping @Sendable () -> UInt64) {
        self.configuration = configuration
        self.uptime = uptime
        thresholdNanos = Self.nanos(configuration.threshold, minimum: 1_000_000)
        sampleAfterNanos = thresholdNanos / 5 * 3
        hangNanos = max(Self.nanos(configuration.hangThreshold, minimum: 1_000_000), thresholdNanos)
    }

    /// `CLOCK_UPTIME_RAW` in nanoseconds: the clock every beat is stamped with.
    public static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func nanos(_ duration: Duration, minimum: UInt64) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return minimum }
        let whole = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .max }
        return max(whole.partialValue.addingReportingOverflow(UInt64(max(attoseconds, 0) / 1_000_000_000)).partialValue, minimum)
    }

    /// Runs on the watched thread after each stall, with the stall's raw stack.
    public var onStall: (@Sendable (Stall) -> Void)? {
        get { stallSink.withLock { $0 } }
        set { stallSink.withLock { $0 = newValue } }
    }

    /// Runs on the watchdog thread when a hang begins and when it ends. Never on the main
    /// thread: a hang file can be written while the main thread is still stuck.
    public var onHang: (@Sendable (Hang) -> Void)? {
        get { hangSink.withLock { $0 } }
        set { hangSink.withLock { $0 = newValue } }
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// The last ``Configuration/capacity`` stalls, oldest first.
    public func recentStalls() -> [Stall] { stalls.withLock { $0 } }

    var currentBeat: UInt64 { beatSequence.load(ordering: .acquiring) }

    /// Watches the main run loop. Call once, on the main thread.
    @MainActor
    public func start() {
        start(runLoop: CFRunLoopGetMain(), thread: mach_thread_self())
    }

    /// Watches `runLoop`, run by `thread` (tests watch a run loop of their own). Called on
    /// that thread.
    func start(runLoop: CFRunLoop, thread: thread_act_t) {
        guard running.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        beatNanos.store(uptime(), ordering: .releasing)
        mainAsleep.store(false, ordering: .releasing)
        let early = CFRunLoopActivity.allActivities.subtracting(.beforeWaiting).rawValue
        let earlyObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, early, true, CFIndex.min) { [weak self] _, activity in
            self?.heartbeat(activity)
        }
        let lateObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, activity in
            self?.heartbeat(activity)
        }
        CFRunLoopAddObserver(runLoop, earlyObserver, .commonModes)
        CFRunLoopAddObserver(runLoop, lateObserver, .commonModes)
        observers.withLock { $0 = ObserverBox([earlyObserver, lateObserver].compactMap { $0 }) }
        let sampler = configuration.sampleStacks ? ThreadStackSampler(thread: thread) : nil
        self.sampler.withLock { $0 = sampler }
        // Without its kqueue the thread could not wait: stalls are still timed on the main thread.
        guard alarm.isAvailable else {
            logger.error("main-thread watchdog: no kqueue; stalls are timed, not sampled")
            return
        }
        let watcher = Thread { [self] in watch(sampler: sampler) }
        watcher.name = "cmux main-thread hang watchdog"
        watcher.qualityOfService = .userInteractive
        watcher.start()
    }

    public func stop() {
        guard running.compareExchange(expected: true, desired: false, ordering: .acquiringAndReleasing).exchanged else { return }
        if let box = observers.withLock({ box in defer { box = nil }; return box }) {
            for observer in box.observers { CFRunLoopObserverInvalidate(observer) }
        }
        alarm.wake()
    }

    // MARK: - Watched (main) thread

    func heartbeat(_ activity: CFRunLoopActivity) {
        let now = uptime()
        let previous = beatNanos.load(ordering: .acquiring)
        let wasAsleep = mainAsleep.load(ordering: .acquiring)
        let beat = beatSequence.load(ordering: .acquiring)
        var stall: Stall?
        var hangEnded = false
        if !wasAsleep, now > previous, now - previous >= thresholdNanos {
            let nanos = now - previous
            var addresses: [UInt] = []
            if publishedSampleBeat.load(ordering: .acquiring) == beat, let sampler = sampler.withLock({ $0 }) {
                addresses = sampler.copy(count: publishedSampleCount.load(ordering: .relaxed))
            }
            stall = Stall(startUptimeNanos: previous, duration: .nanoseconds(Int64(clamping: nanos)), addresses: addresses)
            // Set before the beat moves: the watchdog thread reads it once it sees the new beat.
            if nanos >= hangNanos {
                hangEnded = true
                endedHang.withLock { $0 = (previous, nanos) }
            }
        }
        beatNanos.store(now, ordering: .releasing)
        beatSequence.store(beat &+ 1, ordering: .releasing)
        // The stall is logged on the new beat: the watchdog measures that work as a turn of its
        // own, never as more of the same stall (cmux#50992).
        if let stall { finishStall(stall) }
        let asleep = activity == .beforeWaiting
        mainAsleep.store(asleep, ordering: .releasing)
        if wasAsleep, !asleep {
            // The watchdog thread wakes only if this turn is still running when its sample is due.
            alarm.arm(afterNanos: sampleAfterNanos)
        } else if asleep, !wasAsleep {
            alarm.disarm()
        }
        // A hang ended: the watchdog thread waits with no deadline for this, to report its length.
        if hangEnded { alarm.wake() }
    }

    private func finishStall(_ stall: Stall) {
        let capacity = max(configuration.capacity, 1)
        stalls.withLock { stalls in
            stalls.append(stall)
            if stalls.count > capacity { stalls.removeFirst(stalls.count - capacity) }
        }
        // No symbolication here (main thread): the hang reporter resolves stacks off it.
        logger.notice("main thread stalled \(Double(stall.duration.components.seconds) * 1_000 + Double(stall.duration.components.attoseconds) / 1e15, format: .fixed(precision: 1)) ms (\(stall.addresses.count) frames)")
        stallSink.withLock { $0 }?(stall)
    }

    // MARK: - Watchdog thread

    private struct OpenHang {
        var beat: UInt64
        var start: UInt64
        var addresses: [UInt]
    }

    func watch(sampler: ThreadStackSampler?) {
        // Once with the initial values while nothing is suspended: the first suspended call then
        // fills no Swift runtime cache (a Debug build resolves generic atomics on first use).
        publishSample(count: 0, beat: .max)
        var sampledBeat: UInt64 = .max
        var hang: OpenHang?
        while running.load(ordering: .acquiring) {
            if let open = hang, beatSequence.load(ordering: .acquiring) != open.beat {
                hang = nil
                finishHang(open)
            }
            if mainAsleep.load(ordering: .acquiring) {
                // Parked until a main turn outlasts the sample delay (its alarm) or stop(). A wake
                // between the check and the wait is not lost: the kernel keeps the fired timer.
                waitForAlarm(nanos: nil)
                continue
            }
            let beat = beatSequence.load(ordering: .acquiring)
            let start = beatNanos.load(ordering: .acquiring)
            let now = uptime()
            let elapsed = now > start ? now - start : 0
            if beat != sampledBeat, elapsed >= sampleAfterNanos, stalled(beat) {
                sampledBeat = beat
                if let sampler {
                    // Raw addresses only, published before the thread resumes: atomics only in here.
                    _ = sampler.sample { count in publishSample(count: count, beat: beat) }
                    #if DEBUG
                    afterSampleForTesting.withLock { $0 }?()
                    #endif
                }
            }
            if hang?.beat != beat, elapsed >= hangNanos, stalled(beat) {
                // The stack two seconds in is the hang's: sampled again, and handed to the stall too.
                let addresses = sampler?.sample { count in publishSample(count: count, beat: beat) } ?? []
                let open = OpenHang(beat: beat, start: start, addresses: addresses)
                hang = open
                report(Hang(startUptimeNanos: start, duration: .nanoseconds(Int64(clamping: elapsed)), addresses: addresses, ended: false))
            }
            // The next deadline of this turn; none left: wait for its end (the heartbeat wakes us).
            var next: UInt64?
            if beat != sampledBeat {
                next = sampleAfterNanos > elapsed ? sampleAfterNanos - elapsed : 0
            } else if hang?.beat != beat {
                next = hangNanos > elapsed ? hangNanos - elapsed : 0
            }
            waitForAlarm(nanos: next.map { max($0, 1_000_000) })
        }
        // Stopped mid-hang: the duration so far.
        if let open = hang { finishHang(open) }
    }

    private func stalled(_ beat: UInt64) -> Bool {
        beat == beatSequence.load(ordering: .acquiring) && !mainAsleep.load(ordering: .acquiring)
    }

    private func finishHang(_ open: OpenHang) {
        let ended = endedHang.withLock { $0 }
        let nanos: UInt64
        if let ended, ended.start == open.start {
            nanos = ended.nanos
        } else {
            let now = uptime()
            nanos = now > open.start ? now - open.start : 0
        }
        report(Hang(startUptimeNanos: open.start, duration: .nanoseconds(Int64(clamping: nanos)), addresses: open.addresses, ended: true))
    }

    private func report(_ hang: Hang) {
        let ms = Double(hang.duration.components.seconds) * 1_000 + Double(hang.duration.components.attoseconds) / 1e15
        if hang.ended {
            logger.error("main thread hang ended after \(ms, format: .fixed(precision: 0)) ms (\(hang.addresses.count) frames)")
        } else {
            logger.error("main thread hang: no turn end for \(ms, format: .fixed(precision: 0)) ms (\(hang.addresses.count) frames)")
        }
        hangSink.withLock { $0 }?(hang)
    }

    private func publishSample(count: Int, beat: UInt64) {
        publishedSampleCount.store(count, ordering: .relaxed)
        publishedSampleBeat.store(beat, ordering: .releasing)
    }

    private func waitForAlarm(nanos: UInt64?) {
        // concurrency-allow: the dedicated watchdog thread's kevent wait; never the main thread.
        alarm.wait(nanos: nanos)
        #if DEBUG
        watchdogWakes.add(1, ordering: .relaxed)
        #endif
    }
}

/// The run-loop observers, kept to invalidate them in ``MainThreadHangWatchdog/stop()``.
private final class ObserverBox: @unchecked Sendable { // crash-allow: immutable after init
    let observers: [CFRunLoopObserver]

    init(_ observers: [CFRunLoopObserver]) {
        self.observers = observers
    }
}

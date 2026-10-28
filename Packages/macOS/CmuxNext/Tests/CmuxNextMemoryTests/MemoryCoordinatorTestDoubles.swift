import CmuxNextCompat
import CmuxNextMemory

/// A clock whose time moves only when a test (or a ``RecordingConsumer`` doing work) advances it.
nonisolated final class ManualClock: Clock, Sendable {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    /// The coordinator never sleeps; a sleep is a test failure.
    nonisolated enum SleepError: Error {
        case notSupported
    }

    // A test advances on main; the slice's expiry check reads from the same thread, but Clock is Sendable.
    private let offset = Mutex<Duration>(.zero)

    var now: Instant { Instant(offset: offset.withLock { $0 }) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func advance(by duration: Duration) {
        offset.withLock { $0 += duration }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        throw SleepError.notSupported
    }
}

/// A slicer whose frames the test fires: ``fireFrame()`` runs the slices asked for before it, and
/// records how much clock time each frame took.
@MainActor
final class ManualSlicer: MemoryReleaseSlicer {
    private var pending: [@MainActor () -> Void] = []
    private let clock: ManualClock
    /// How many slices were asked for since the start.
    private(set) var requests = 0
    /// The clock time each fired frame took.
    private(set) var frameDurations: [Duration] = []

    init(clock: ManualClock) {
        self.clock = clock
    }

    var hasPendingSlice: Bool { !pending.isEmpty }

    func scheduleSlice(_ slice: @escaping @MainActor () -> Void) {
        requests += 1
        pending.append(slice)
    }

    /// Runs the slices asked for before this call (one frame). Returns whether any ran.
    @discardableResult
    func fireFrame() -> Bool {
        let slices = pending
        pending = []
        guard !slices.isEmpty else { return false }
        let start = clock.now
        for slice in slices { slice() }
        frameDurations.append(start.duration(to: clock.now))
        return true
    }

    /// Fires frames until none is asked for, at most `limit`. Returns how many ran.
    @discardableResult
    func drain(limit: Int = 10_000) -> Int {
        var frames = 0
        while frames < limit, fireFrame() { frames += 1 }
        return frames
    }
}

/// What every ``RecordingConsumer`` was told, in order.
@MainActor
final class CallLog {
    enum Call: Equatable {
        case limit(String, Int)
        case release(String)
    }

    private(set) var calls: [Call] = []

    func record(_ call: Call) {
        calls.append(call)
    }

    func clear() {
        calls = []
    }

    var releases: [String] {
        calls.compactMap { call in
            guard case .release(let name) = call else { return nil }
            return name
        }
    }
}

/// A consumer that holds `fullEntries` entries and frees one per `costPerEntry` of clock time,
/// checking the slice before each one.
@MainActor
final class RecordingConsumer: MemoryConsumer {
    let name: String
    let fullEntries: Int
    private(set) var entries: Int
    private(set) var limit = MemoryLimit.default
    private let costPerEntry: Duration
    private let clock: ManualClock
    private let log: CallLog
    /// Runs inside the next release call, once (a consumer that registers another mid-release).
    var duringNextRelease: (@MainActor () -> Void)?

    init(name: String, entries: Int = 4, costPerEntry: Duration = .microseconds(100), clock: ManualClock, log: CallLog) {
        self.name = name
        fullEntries = entries
        self.entries = entries
        self.costPerEntry = costPerEntry
        self.clock = clock
        self.log = log
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        self.limit = limit
        log.record(.limit(name, limit.percent))
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        log.record(.release(name))
        if let hook = duringNextRelease {
            duringNextRelease = nil
            hook()
        }
        let cap = slice.limit.scale(fullEntries)
        while entries > cap {
            if slice.isExpired { return .more }
            entries -= 1
            clock.advance(by: costPerEntry)
        }
        return .done
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: entries * 1_024, entries: entries)
    }
}

/// A consumer that frees one entry per release call and yields the rest of the slice, as the
/// terminal warm set closes one surface per frame.
@MainActor
final class PacedConsumer: MemoryConsumer {
    let name: String
    let fullEntries: Int
    private(set) var entries: Int
    private let log: CallLog

    init(name: String, entries: Int, log: CallLog) {
        self.name = name
        fullEntries = entries
        self.entries = entries
        self.log = log
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        log.record(.limit(name, limit.percent))
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        log.record(.release(name))
        let cap = slice.limit.scale(fullEntries)
        guard entries > cap else { return .done }
        entries -= 1
        return entries > cap ? .yield : .done
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: entries * 1_024, entries: entries)
    }
}

/// Traits of a managed consumer, with the parts the coordinator orders and limits by.
@MainActor
func managedTraits(
    dataAccess: MemoryConsumerTraits.DataAccess = .none,
    retention: MemoryConsumerTraits.Retention = .lossless,
    recreateCost: MemoryConsumerTraits.RecreateCost = .cheap,
    releaseCPUCost: MemoryConsumerTraits.ReleaseCPUCost = .low,
    estimatedUsage: MemoryConsumerTraits.EstimatedUsage = .medium
) -> MemoryConsumerTraits {
    MemoryConsumerTraits(
        estimatedUsage: estimatedUsage, dataAccess: dataAccess, retention: retention, recreateCost: recreateCost,
        releaseCPUCost: releaseCPUCost, isStateful: true, supportsMemoryLimit: true)
}

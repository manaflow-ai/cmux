// The inputs and the counters of intent prewarm, beside its state in IntentPrewarm.swift.

/// The power inputs a prewarm reads. The composition root pushes Energy Saver's inputs
/// (`EnergyMonitor.follow`) into the service's `power`; CmuxNextInput does not import CmuxNextEnergy.
public struct IntentPrewarmPower: Sendable, Equatable {
    /// macOS Low Power Mode is on.
    public var lowPowerMode: Bool
    /// The battery provides power.
    public var onBattery: Bool

    public init(lowPowerMode: Bool = false, onBattery: Bool = false) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
    }

    /// Low Power Mode on battery: no prewarm starts, as Chrome starts no preload under Battery Saver
    /// (content/public/browser/preloading.h, `PreloadingEligibility::kBatterySaverEnabled`).
    public var savesBattery: Bool { lowPowerMode && onBattery }
}

/// Main-thread durations of one kind of intent-prewarm work, in `CLOCK_UPTIME_RAW` nanoseconds: the newest
/// ``limit`` kept in a ring (the oldest overwritten), so a bench reads their distribution (p50/p95/p99/max).
public struct IntentPrewarmDurations: Sendable, Equatable {
    /// How many durations are kept.
    public static let limit = 512
    private var ring: [UInt64] = []
    private var next = 0

    public init() {}

    /// The kept durations, oldest first.
    public var nanoseconds: [UInt64] {
        ring.count < Self.limit ? ring : Array(ring[next...] + ring[..<next])
    }

    /// Keeps `nanos`, dropping the oldest past ``limit``. O(1): it runs on the press's turn.
    public mutating func record(_ nanos: UInt64) {
        if ring.count < Self.limit {
            ring.append(nanos)
        } else {
            ring[next] = nanos
            next = (next + 1) % Self.limit
        }
    }
}

/// What the service did, for `debug.input` section `prewarm` (hover and press prewarms are counted apart from
/// plain clicks and from each other). scripts/cmux-next/bench-prewarm-press.py reads the press durations
/// (``pressTurns``, ``pressStarts``); no bench reads the hit counters yet.
public struct IntentPrewarmCounters: Sendable, Equatable {
    /// Prewarms started, by trigger.
    public var started: [IntentPrewarmTrigger: Int] = [:]
    /// Prewarms the FIFO evicted before their target committed.
    public var evicted = 0
    /// Prewarms whose target committed while they were in the FIFO.
    public var used = 0
    /// ``used`` by the trigger that started each, so benches report press hits apart from hover hits.
    public var hits: [IntentPrewarmTrigger: Int] = [:]
    /// Prewarms cancelled by critical memory pressure.
    public var cancelledByPressure = 0
    /// Key-step prewarms cancelled by a step the other way.
    public var cancelledByDirection = 0
    /// Dwells and presses that started nothing because of Low Power Mode on battery.
    public var skippedForPower = 0
    /// Dwells and presses that started nothing because of memory pressure (warning or worse).
    public var skippedForPressure = 0
    /// The service's main-thread time on each press's own turn (the app's target lookup, `intentPrewarmPress`'s
    /// admit and the hover dwell's cancel): the cost the prewarm adds to the press.
    public var pressTurns = IntentPrewarmDurations()
    /// Each run of the press deadline (the held press prewarms' warmer work, after the press's turn).
    public var pressStarts = IntentPrewarmDurations()

    public init() {}
}

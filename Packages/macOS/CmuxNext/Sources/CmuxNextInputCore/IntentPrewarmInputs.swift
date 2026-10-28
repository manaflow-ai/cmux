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

/// What the service did, for debug.input, bench_hibernation.py and activation-perf.py (hover and press
/// prewarms are reported apart from plain clicks and from each other).
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

    public init() {}
}

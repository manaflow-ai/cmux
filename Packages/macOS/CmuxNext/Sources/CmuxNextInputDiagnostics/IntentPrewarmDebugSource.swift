public import CmuxNextInput
public import CmuxNextInputCore

/// `debug.input` section `prewarm`: what intent prewarm did, so activation-perf.py and
/// bench_hibernation.py report prewarm hits apart from plain clicks, and press hits apart from hover hits.
public nonisolated struct DebugInputPrewarm: Sendable, Equatable, Codable {
    /// Prewarms started, by ``IntentPrewarmTrigger`` raw value (`pointerDown`, `hoverDwell`).
    public var started: [String: Int]
    /// Prewarms whose target committed while held, by the trigger that started them.
    public var hits: [String: Int]
    /// Prewarms the FIFO evicted before their target committed.
    public var evicted: Int
    /// Prewarms cancelled by critical memory pressure.
    public var cancelledByPressure: Int
    /// Hovers and presses that started nothing because of Low Power Mode on battery.
    public var skippedForPower: Int
    /// Hovers and presses that started nothing because of memory pressure.
    public var skippedForPressure: Int
    /// Prewarms held now (at most the FIFO's limit, 2).
    public var held: Int

    public init(counters: IntentPrewarmCounters, held: Int) {
        started = Dictionary(counters.started.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
        hits = Dictionary(counters.hits.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
        evicted = counters.evicted
        cancelledByPressure = counters.cancelledByPressure
        skippedForPower = counters.skippedForPower
        skippedForPressure = counters.skippedForPressure
        self.held = held
    }

    private enum CodingKeys: String, CodingKey {
        case started, hits, evicted, held
        case cancelledByPressure = "cancelled_by_pressure"
        case skippedForPower = "skipped_for_power"
        case skippedForPressure = "skipped_for_pressure"
    }
}

/// The `prewarm` section's producer over the app's intent prewarm service, read in one main-actor copy.
/// The service exists only while `intentPrewarmHover` or `intentPrewarmPress` is on; without it the section
/// reads zeros.
///
/// ```swift
/// IntentPrewarmDebugSource { [weak services] in services?.cache.hibernation?.intentPrewarm?.service }
/// ```
public nonisolated struct IntentPrewarmDebugSource: DebugInputSource {
    private let readCounters: @MainActor @Sendable () -> DebugInputPrewarm?
    private let resetCounters: @MainActor @Sendable () -> Void

    /// - Parameter service: The app's intent prewarm service now; nil while neither feature is on.
    public init<Target: Hashable & Sendable>(service: @escaping @MainActor @Sendable () -> IntentPrewarmService<Target>?) {
        readCounters = { service().map { DebugInputPrewarm(counters: $0.counters, held: $0.queue.held.count) } }
        resetCounters = { service()?.resetCounters() }
    }

    public var section: DebugInputSection { .prewarm }

    public func read() async -> DebugInputPrewarm {
        await readCounters() ?? DebugInputPrewarm(counters: IntentPrewarmCounters(), held: 0)
    }

    public func reset() async {
        await resetCounters()
    }
}

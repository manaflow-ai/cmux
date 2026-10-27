import CmuxNextWakeups

/// One reading of the power source: what IOKit reports in one snapshot.
public nonisolated struct PowerSourceReading: Sendable, Equatable {
    /// The battery provides power.
    public var onBattery: Bool
    /// This Mac has an internal battery.
    public var hasBattery: Bool
    /// The internal battery's charge in percent; nil without a battery or a capacity.
    public var batteryPercent: Int?

    /// A reading with every field given (the default: a Mac on AC with no battery).
    public init(onBattery: Bool = false, hasBattery: Bool = false, batteryPercent: Int? = nil) {
        self.onBattery = onBattery
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
    }
}

/// Where ``EnergyMonitor`` gets the power source: IOKit's, followed off the main thread (``system(mainWork:)``), or a test's.
public struct PowerSourceInput {
    /// Starts sending readings to the handler on the main actor: the first one, then the changes
    /// the source reports. A Mac without a battery sends none and registers nothing.
    let start: @MainActor (@escaping @MainActor @Sendable (PowerSourceReading) -> Void) -> Void
    /// Stops what `start` started.
    let stop: @MainActor () -> Void

    /// A power source read by `read` on the main actor, whose changes `listen` reports until `stop`:
    /// `read` once at start (no battery: nothing more, `listen` never called), then once per change.
    public init(read: @escaping @MainActor () -> PowerSourceReading,
                listen: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
                stop: @escaping @MainActor () -> Void = {}) {
        self.init(start: { deliver in
            let first = read()
            guard first.hasBattery else { return }
            listen { deliver(read()) }
            deliver(first)
        }, stop: stop)
    }

    init(start: @escaping @MainActor (@escaping @MainActor @Sendable (PowerSourceReading) -> Void) -> Void,
         stop: @escaping @MainActor () -> Void) {
        self.start = start
        self.stop = stop
    }

    /// IOKit: the app's one power-source monitor (``PowerSourceMonitor``), which reads on its utility
    /// queue and posts to `mainWork` only when the source or the low-battery band changes.
    static func system(mainWork: MainWorkScheduler) -> PowerSourceInput {
        monitored(by: PowerSourceMonitor(system: .live(mainWork: mainWork)))
    }

    /// The input `monitor` feeds.
    static func monitored(by monitor: PowerSourceMonitor) -> PowerSourceInput {
        PowerSourceInput(start: { monitor.start($0) }, stop: { monitor.stop() })
    }
}

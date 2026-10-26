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

/// Where ``EnergyMonitor`` reads the power source: IOKit's (``system()``), or a test's.
public struct PowerSourceInput {
    /// The power source now, one snapshot per call.
    let read: @MainActor () -> PowerSourceReading
    /// Starts calling the handler on the main actor after each power-source change.
    let listen: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// Stops what `listen` started.
    let stop: @MainActor () -> Void

    /// A power source read by `read`, whose changes `listen` reports until `stop`.
    public init(read: @escaping @MainActor () -> PowerSourceReading,
                listen: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void,
                stop: @escaping @MainActor () -> Void = {}) {
        self.read = read
        self.listen = listen
        self.stop = stop
    }

    /// IOKit: the app's one power-source run-loop source (``PowerSourceMonitor``).
    static func system() -> PowerSourceInput {
        let monitor = PowerSourceMonitor()
        return PowerSourceInput(read: { PowerSourceMonitor.read() }, listen: { handler in
            monitor.onChange = handler
            monitor.start()
        }, stop: { monitor.stop() })
    }
}

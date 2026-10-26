#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// Power inputs `debug.energy.simulate` lays over the Mac's (Debug and bench builds only,
/// p14-energy-123): each non-nil field replaces that input of the energy monitor (Low Power Mode and the
/// thermal state through their seams' overrides, so every reader sees them), each nil field
/// follows the Mac. Fleet Macs have no battery, so this is how a bench sees Energy Saver's battery and
/// thermal reasons. A core value next to ``EnergyPolicy``: the control method parses it and the
/// composition root hands it to its energy monitor.
public struct EnergySimulation: Sendable, Equatable {
    public var onBattery: Bool?
    /// The battery's charge in percent, clamped to 0-100; reported only while on battery.
    public var batteryPercent: Int?
    public var thermal: ProcessInfo.ThermalState?
    public var lowPowerMode: Bool?
    /// The Mac is going to sleep or asleep (``EnergyPolicy/suspended``).
    public var suspended: Bool?

    /// A simulation of the given inputs; the rest follow the Mac.
    public init(onBattery: Bool? = nil, batteryPercent: Int? = nil, thermal: ProcessInfo.ThermalState? = nil,
                lowPowerMode: Bool? = nil, suspended: Bool? = nil) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent.map { min(max($0, 0), 100) }
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.suspended = suspended
    }
}
#endif

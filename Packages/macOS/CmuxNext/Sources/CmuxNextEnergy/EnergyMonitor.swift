public import CmuxNextCompat
public import Foundation
import Observation

/// The power inputs Energy Saver decides from, as one value (plans/cmux-next/chrome-parity/p14-energy.md D).
public nonisolated struct EnergyInputs: Sendable, Equatable {
    /// macOS Low Power Mode is on (its debug override included).
    public var lowPowerMode: Bool
    /// The battery provides power.
    public var onBattery: Bool
    /// This Mac has an internal battery.
    public var hasBattery: Bool
    /// The battery's charge in percent; read only while on battery, else nil.
    public var batteryPercent: Int?
    /// The Mac's thermal state.
    public var thermal: ProcessInfo.ThermalState

    /// Inputs with every field given.
    public init(lowPowerMode: Bool = false, onBattery: Bool = false, hasBattery: Bool = false,
                batteryPercent: Int? = nil, thermal: ProcessInfo.ThermalState = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

/// Where ``EnergyMonitor`` reads the power source: IOKit's (``system()``), or a test's.
struct PowerSourceInput {
    /// Whether the battery provides power now.
    let onBattery: @MainActor () -> Bool
    /// The internal battery now.
    let battery: @MainActor () -> BatteryLevel
    /// Starts calling the handler on the main actor after each power-source change.
    let listen: @MainActor (@escaping @MainActor () -> Void) -> Void

    /// IOKit: the app's one power-source run-loop source (``PowerSourceMonitor``).
    static func system() -> PowerSourceInput {
        let monitor = PowerSourceMonitor()
        return PowerSourceInput(onBattery: { PowerSourceMonitor.onBattery() }, battery: { BatteryLevel.read() }) { handler in
            monitor.onChange = handler
            monitor.start()
        }
    }
}

/// Energy Saver's one owner of power inputs: Low Power Mode, the power source, the battery's
/// charge and the thermal state, each observed once for the app. The composition root makes one
/// and hands its parts out by init or pushes its ``inputs`` to the consumers below it; only
/// CmuxNextApp imports this module. Chrome keeps the same inputs in its battery saver's manager
/// (components/performance_manager/user_tuning/battery_saver_mode_manager.cc).
///
/// Nothing touches IOKit before ``start()``, and a Mac without a battery registers no
/// power-source notification at all: it can never run on battery (a UPS counts as AC).
@MainActor
@Observable
public final class EnergyMonitor {
    /// The inputs now.
    public private(set) var inputs: EnergyInputs
    /// Low Power Mode, which the hibernation, the glass watch and `debug.low_power_mode` read.
    public let lowPowerMode: LowPowerMode
    /// The thermal state (its `override` for debug).
    public let thermal: ThermalStateWatch

    private let power: PowerSourceInput
    private let handlers = MainActorHandlers<EnergyInputs>()
    @ObservationIgnored private var lowPowerObservation: LowPowerModeObservation?
    @ObservationIgnored private var onBattery = false
    @ObservationIgnored private var battery = BatteryLevel()
    @ObservationIgnored private var started = false

    /// The system's inputs: macOS Low Power Mode, IOKit's power source, the thermal state.
    public convenience init() {
        self.init(lowPowerMode: .system(), thermal: .system(), power: .system())
    }

    /// A monitor over these inputs (tests pass fixed ones).
    init(lowPowerMode: LowPowerMode, thermal: ThermalStateWatch, power: PowerSourceInput) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.power = power
        inputs = EnergyInputs(lowPowerMode: lowPowerMode.isEnabled, thermal: thermal.state)
        lowPowerObservation = lowPowerMode.observe { [weak self] _ in self?.refresh() }
        thermal.onChange = { [weak self] _ in self?.refresh() }
    }

    /// Reads the power source and follows its changes; a second call does nothing.
    public func start() {
        guard !started else { return }
        started = true
        battery = power.battery()
        guard battery.hasBattery else { return }
        power.listen { [weak self] in self?.readPowerSource() }
        readPowerSource()
    }

    /// Calls `handler` with the new inputs after each change, until the returned registration is
    /// released (on any thread) or cancelled.
    public func observe(_ handler: @escaping @MainActor @Sendable (EnergyInputs) -> Void) -> MainActorHandlerRegistration<EnergyInputs> {
        handlers.add(handler)
    }

    /// Calls `handler` with the inputs now, then as ``observe(_:)`` does.
    public func follow(_ handler: @escaping @MainActor @Sendable (EnergyInputs) -> Void) -> MainActorHandlerRegistration<EnergyInputs> {
        handler(inputs)
        return observe(handler)
    }

    private func readPowerSource() {
        onBattery = power.onBattery()
        // The charge matters only on battery: on AC the last reading stays and nothing reports it.
        if onBattery { battery = power.battery() }
        refresh()
    }

    private func refresh() {
        let next = EnergyInputs(lowPowerMode: lowPowerMode.isEnabled, onBattery: onBattery, hasBattery: battery.hasBattery,
                                batteryPercent: onBattery ? battery.percent : nil, thermal: thermal.state)
        guard next != inputs else { return }
        inputs = next
        handlers.call(next)
    }
}

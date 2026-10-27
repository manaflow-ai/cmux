public import CmuxNextCompat
#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextWakeups
#endif
public import Foundation
import Observation

/// The power inputs Energy Saver decides from, as one value (plans/cmux-next/chrome-parity/p14-energy.md D).
public nonisolated struct EnergyInputs: Sendable, Equatable {
    /// macOS Low Power Mode is on (its debug override included).
    public var lowPowerMode: Bool
    /// The battery provides power.
    public var onBattery: Bool
    /// The Mac's own power source is the battery, whatever `debug.energy.simulate` lays over
    /// ``onBattery``: the resolver's plug-in edge, which ends "Turn Off for Now", follows only this.
    public var macOnBattery: Bool
    /// This Mac has an internal battery.
    public var hasBattery: Bool
    /// The battery's charge in percent; reported only while on battery, else nil. Above the low-battery
    /// threshold it is the charge when the source last changed: the Mac's charge steps reach the main
    /// thread only below it (``PowerSourceMonitor/Edge``).
    public var batteryPercent: Int?
    /// The Mac's thermal state.
    public var thermal: ProcessInfo.ThermalState
    /// The Mac is going to sleep or asleep (``EnergyPolicy/suspended``): the ``SuspendWatch``'s, or
    /// `debug.energy.simulate`'s.
    public var suspended: Bool
    /// The displays sleep (``EnergyPolicy/screensAsleep``).
    public var screensAsleep: Bool
    /// The wakes whose network path came back (``EnergyPolicy/networkResumes``).
    public var networkResumes: UInt64

    /// Inputs with every field given; `macOnBattery` nil is `onBattery` (nothing simulated).
    public init(lowPowerMode: Bool = false, onBattery: Bool = false, macOnBattery: Bool? = nil, hasBattery: Bool = false,
                batteryPercent: Int? = nil, thermal: ProcessInfo.ThermalState = .nominal, suspended: Bool = false,
                screensAsleep: Bool = false, networkResumes: UInt64 = 0) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.macOnBattery = macOnBattery ?? onBattery
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.suspended = suspended
        self.screensAsleep = screensAsleep
        self.networkResumes = networkResumes
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension EnergyInputs {
    /// These inputs with `simulation`'s power source, charge and sleep over them; ``macOnBattery`` stays
    /// the Mac's. Simulating battery power or a charge gives the Mac a battery; the monitor drops the charge
    /// when the result is not on battery, as it does the Mac's. Low Power Mode and the thermal state reach
    /// the inputs through their seams' overrides (``EnergyMonitor/simulate(_:)``), not here.
    nonisolated func simulated(by simulation: EnergySimulation) -> EnergyInputs {
        var inputs = self
        if let onBattery = simulation.onBattery {
            inputs.onBattery = onBattery
            inputs.hasBattery = inputs.hasBattery || onBattery
        }
        if let batteryPercent = simulation.batteryPercent {
            inputs.batteryPercent = batteryPercent
            inputs.hasBattery = true
        }
        if let suspended = simulation.suspended { inputs.suspended = suspended }
        return inputs
    }
}
#endif

/// Energy Saver's one owner of power inputs: Low Power Mode, the power source, the battery's
/// charge, the thermal state and (once ``follow(suspend:)`` hands it one) the Mac's sleep and wake,
/// each observed once for the app. The composition root makes one
/// and hands its parts out by init or pushes its ``inputs`` to the consumers below it; only
/// CmuxNextApp imports this module. Chrome keeps the same inputs in its battery saver's manager
/// (components/performance_manager/user_tuning/battery_saver_mode_manager.cc).
///
/// Nothing touches IOKit before ``start()``, the power source is read off the main thread, and a Mac
/// without a battery registers no power-source notification at all: it can never run on battery (a UPS
/// counts as AC).
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
    /// The sleep, wake and display sleep watch; nil reports the Mac awake.
    @ObservationIgnored private var suspend: SuspendWatch?
    private let handlers = MainActorHandlers<EnergyInputs>()
    @ObservationIgnored private var lowPowerObservation: LowPowerModeObservation?
    @ObservationIgnored private var reading = PowerSourceReading()
    @ObservationIgnored private var started = false
    #if DEBUG || CMUX_BENCH_HOOKS
    /// What `debug.energy.simulate` lays over the Mac's inputs; nil follows the Mac.
    @ObservationIgnored public private(set) var simulation: EnergySimulation?
    /// The Low Power Mode override held before the simulation took that seam; nil while it does not hold it.
    @ObservationIgnored private var lowPowerModeBeforeSimulation: Bool??
    /// The thermal override held before the simulation took that seam; nil while it does not hold it.
    @ObservationIgnored private var thermalBeforeSimulation: ProcessInfo.ThermalState??
    /// ``simulate(_:)`` is setting the seams' overrides: their change notes wait for its one refresh.
    @ObservationIgnored private var isApplyingSimulation = false
    #endif

    /// The system's inputs: macOS Low Power Mode, IOKit's power source, the thermal state.
    public convenience init() {
        self.init(lowPowerMode: .system(), thermal: .system(), power: .system())
    }

    /// A monitor over these inputs (tests pass fixed ones).
    public init(lowPowerMode: LowPowerMode, thermal: ThermalStateWatch, power: PowerSourceInput) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.power = power
        inputs = EnergyInputs(lowPowerMode: lowPowerMode.isEnabled, thermal: thermal.state)
        lowPowerObservation = lowPowerMode.observe { [weak self] _ in self?.refresh() }
        thermal.onChange = { [weak self] _ in self?.refresh() }
    }

    /// Follows the power source; a second call does nothing. A Mac without a battery registers nothing
    /// and its inputs keep `hasBattery` false.
    public func start() {
        guard !started else { return }
        started = true
        power.start { [weak self] reading in self?.apply(reading) }
    }

    /// Stops following the power source (its notifications end); ``start()`` may run again.
    public func stop() {
        guard started else { return }
        started = false
        power.stop()
    }

    /// Starts `watch` and reports its sleep, wake and display sleep from now on, in place of an earlier
    /// watch (which stops). The composition root hands it the app's one watch.
    public func follow(suspend watch: SuspendWatch) {
        guard watch !== suspend else { return }
        suspend?.onChange = nil
        suspend?.stop()
        suspend = watch
        watch.onChange = { [weak self] _ in self?.refresh() }
        watch.start()
        refresh()
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

    /// `debug.energy.simulate` lays inputs over the Mac's; never in Release without bench hooks.
    public var isSimulated: Bool {
        #if DEBUG || CMUX_BENCH_HOOKS
        simulation != nil
        #else
        false
        #endif
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Lays `simulation` over the Mac's inputs from now on, replacing an earlier one; nil restores the
    /// Mac's. Low Power Mode and the thermal state go through ``lowPowerMode`` and ``thermal``'s
    /// overrides, so their other readers (hibernation, the glass watch) see the same Mac. A seam the new
    /// simulation leaves out, or nil, gets back the override it held before a simulation took it
    /// (`debug.low_power_mode`'s, say); a seam no simulation took is left alone. Observers hear one
    /// change, so the policy follows in the same turn.
    public func simulate(_ simulation: EnergySimulation?) {
        self.simulation = simulation
        isApplyingSimulation = true
        lowPowerMode.override = Self.override(simulation?.lowPowerMode, now: lowPowerMode.override,
                                              before: &lowPowerModeBeforeSimulation)
        thermal.override = Self.override(simulation?.thermal, now: thermal.override, before: &thermalBeforeSimulation)
        isApplyingSimulation = false
        refresh()
    }

    /// A seam's next override: `simulated`, keeping the one it holds `now` in `before`; with no
    /// `simulated`, the kept one if the simulation held the seam, else `now`.
    private static func override<Value>(_ simulated: Value?, now: Value?, before: inout Value??) -> Value? {
        if let simulated {
            if before == nil { before = .some(now) }
            return simulated
        }
        guard let held = before else { return now }
        before = nil
        return held
    }
    #endif

    private func apply(_ next: PowerSourceReading) {
        reading = next
        refresh()
    }

    private func refresh() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard !isApplyingSimulation else { return }
        #endif
        let sleep = suspend?.state ?? SuspendWatch.State()
        var next = EnergyInputs(lowPowerMode: lowPowerMode.isEnabled, onBattery: reading.onBattery, hasBattery: reading.hasBattery,
                                batteryPercent: reading.batteryPercent, thermal: thermal.state, suspended: sleep.suspended,
                                screensAsleep: sleep.screensAsleep, networkResumes: sleep.networkResumes)
        #if DEBUG || CMUX_BENCH_HOOKS
        if let simulation { next = next.simulated(by: simulation) }
        #endif
        if !next.onBattery { next.batteryPercent = nil }
        guard next != inputs else { return }
        inputs = next
        handlers.call(next)
    }
}

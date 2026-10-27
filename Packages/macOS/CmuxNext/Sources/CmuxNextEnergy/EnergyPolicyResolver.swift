public import CmuxNextWakeups
import Foundation

/// Turns the `energy.saver` setting and the power inputs (``EnergyInputs``) into Energy Saver on or
/// off, with the reason, and keeps the session's "Turn Off Energy Saver for Now". Pure: no clock,
/// no I/O, no observers. The composition root feeds it each change of the setting or of
/// `EnergyMonitor.inputs` and builds the ``EnergyPolicy`` from the returned reason
/// (`EnergyPolicy(saverReason:)`).
///
/// Chrome's rule (`chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc`):
/// `kEnabled` is always on, `kEnabledOnBattery` on while on battery power, `kEnabledBelowThreshold`
/// on while on battery with `battery_percentage_ < kLowBatteryThresholdPercent` (20, strictly
/// below). `SetTemporaryBatterySaverDisabledForSession` holds the saver off until the device is
/// plugged in or the pref changes (`OnBatterySaverModePrefChanged`). Here `always`, `onBattery`
/// and the battery part of `auto` follow it, and so does "Turn Off for Now".
///
/// Where cmux differs from Chrome, in `auto` only (plans/cmux-next/chrome-parity/p14-energy.md, D):
/// - macOS Low Power Mode turns the saver on, plugged in or not: the person asked the Mac to save
///   power. Chrome reads no Low Power Mode.
/// - Thermal state serious or critical turns it on, but only on battery: a desktop under build load
///   must not throttle visible pages or change benches. Chrome has no thermal trigger. The thermal
///   reason then holds until the Mac cools to nominal or is plugged in, so a Mac that moves between
///   fair and serious under load turns the saver on once, not on each move (Chrome's saver changes
///   only on a pref, power source or battery threshold edge, none of which flaps).
public nonisolated struct EnergyPolicyResolver: Sendable, Equatable {
    /// On battery below this charge (strictly), `auto` turns the saver on: Chrome's
    /// `kLowBatteryThresholdPercent`.
    public static let lowBatteryThresholdPercent = 20

    /// The `energySaver` feature. Off, the saver never turns on, whatever the setting says.
    public let isEnabled: Bool
    /// "Turn Off for Now" holds: the saver stays off until the battery -> AC edge or a setting change.
    public private(set) var isOffForSession = false
    private var lastSetting: EnergySaverMode?
    /// The Mac's own power source at the last update (``EnergyInputs/macOnBattery``).
    private var lastOnBattery = false
    /// On battery, the Mac reached serious and has not cooled to nominal since (the thermal hold).
    private var isThermalHeld = false

    /// A resolver that has seen no inputs yet, with "Turn Off for Now" not held.
    ///
    /// - Parameter isEnabled: The `energySaver` feature is on.
    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Why the saver is on for `setting` and `inputs` with this session's state, or nil while it is
    /// off. Changes nothing.
    public func reason(setting: EnergySaverMode, inputs: EnergyInputs) -> EnergyPolicy.Reason? {
        guard isEnabled, !isOffForSession else { return nil }
        switch setting {
        case .off:
            return nil
        case .always:
            return .setting
        case .onBattery:
            return inputs.onBattery ? .setting : nil
        case .auto:
            return Self.autoReason(inputs, thermalHeld: isThermalHeld)
        }
    }

    /// Takes the setting and inputs now and returns ``reason(setting:inputs:)`` for them. The
    /// battery -> AC edge and any change of the setting end "Turn Off for Now", as
    /// `battery_saver_mode_manager.cc` does. The edge is the Mac's own (``EnergyInputs/macOnBattery``):
    /// a `debug.energy.simulate` power source never ends it.
    public mutating func update(setting: EnergySaverMode, inputs: EnergyInputs) -> EnergyPolicy.Reason? {
        let settingChanged = lastSetting.map { $0 != setting } ?? false
        if settingChanged || (lastOnBattery && !inputs.macOnBattery) {
            isOffForSession = false
        }
        lastSetting = setting
        lastOnBattery = inputs.macOnBattery
        isThermalHeld = Self.isHot(inputs, held: isThermalHeld)
        return reason(setting: setting, inputs: inputs)
    }

    /// "Turn Off Energy Saver for Now" (action `energy.saver.turnOffForNow`).
    public mutating func turnOffForNow() {
        isOffForSession = true
    }

    /// Ends "Turn Off for Now" before its edge (action `energy.saver.turnOnNow`).
    public mutating func turnOnNow() {
        isOffForSession = false
    }

    private static func autoReason(_ inputs: EnergyInputs, thermalHeld: Bool) -> EnergyPolicy.Reason? {
        if inputs.lowPowerMode { return .lowPowerMode }
        guard inputs.onBattery else { return nil }
        if inputs.hasBattery, let percent = inputs.batteryPercent, percent < lowBatteryThresholdPercent {
            return .battery
        }
        return isHot(inputs, held: thermalHeld) ? .thermal : nil
    }

    /// On battery and serious or critical, or above nominal while the hold from an earlier serious state lasts.
    private static func isHot(_ inputs: EnergyInputs, held: Bool) -> Bool {
        guard inputs.onBattery else { return false }
        let level = inputs.thermal.rawValue
        return level >= ProcessInfo.ThermalState.serious.rawValue
            || (held && level > ProcessInfo.ThermalState.nominal.rawValue)
    }
}

@testable import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// `energy.saver` and the power inputs -> Energy Saver on or off with its reason, and the session's
/// "Turn Off for Now" (Chrome's battery_saver_mode_manager.cc, plus cmux's Low Power Mode and
/// thermal triggers in `auto`).
nonisolated struct EnergyPolicyResolverTests {
    /// One row: the setting, the inputs and the reason the saver is on for (nil: off).
    nonisolated struct Row: Sendable, CustomTestStringConvertible {
        let setting: EnergySaverMode
        let inputs: EnergyInputs
        let reason: EnergyPolicy.Reason?
        let label: String

        var testDescription: String { "\(setting.rawValue), \(label) -> \(reason?.rawValue ?? "off")" }
    }

    /// A laptop on battery at `percent`.
    static func battery(_ percent: Int, thermal: ProcessInfo.ThermalState = .nominal,
                        lowPowerMode: Bool = false) -> EnergyInputs {
        EnergyInputs(lowPowerMode: lowPowerMode, onBattery: true, hasBattery: true, batteryPercent: percent, thermal: thermal)
    }

    /// A laptop on the adapter: the monitor reports no charge while plugged in.
    static func plugged(thermal: ProcessInfo.ThermalState = .nominal, lowPowerMode: Bool = false) -> EnergyInputs {
        EnergyInputs(lowPowerMode: lowPowerMode, onBattery: false, hasBattery: true, batteryPercent: nil, thermal: thermal)
    }

    /// A desktop Mac: no battery, never on battery.
    static func desktop(thermal: ProcessInfo.ThermalState = .nominal, lowPowerMode: Bool = false) -> EnergyInputs {
        EnergyInputs(lowPowerMode: lowPowerMode, thermal: thermal)
    }

    static let table: [Row] = [
        // always: on everywhere, whatever the inputs.
        Row(setting: .always, inputs: plugged(), reason: .setting, label: "plugged in"),
        Row(setting: .always, inputs: battery(90), reason: .setting, label: "battery 90%"),
        Row(setting: .always, inputs: desktop(), reason: .setting, label: "desktop"),
        Row(setting: .always, inputs: battery(5, thermal: .critical, lowPowerMode: true), reason: .setting,
            label: "battery 5%, critical, Low Power Mode"),
        // onBattery: on battery at any charge; Low Power Mode and heat do not matter.
        Row(setting: .onBattery, inputs: battery(90), reason: .setting, label: "battery 90%"),
        Row(setting: .onBattery, inputs: battery(5), reason: .setting, label: "battery 5%"),
        Row(setting: .onBattery, inputs: plugged(), reason: nil, label: "plugged in"),
        Row(setting: .onBattery, inputs: plugged(lowPowerMode: true), reason: nil, label: "plugged in, Low Power Mode"),
        Row(setting: .onBattery, inputs: desktop(thermal: .critical), reason: nil, label: "desktop, critical"),
        // off: never, even in Low Power Mode on a hot, empty battery.
        Row(setting: .off, inputs: battery(1, thermal: .critical, lowPowerMode: true), reason: nil,
            label: "battery 1%, critical, Low Power Mode"),
        Row(setting: .off, inputs: plugged(lowPowerMode: true), reason: nil, label: "plugged in, Low Power Mode"),
        // auto, battery: strictly below 20%, as Chrome's `battery_percentage_ < 20`.
        Row(setting: .auto, inputs: battery(19), reason: .battery, label: "battery 19%"),
        Row(setting: .auto, inputs: battery(20), reason: nil, label: "battery 20%"),
        Row(setting: .auto, inputs: battery(0), reason: .battery, label: "battery 0%"),
        Row(setting: .auto, inputs: battery(80), reason: nil, label: "battery 80%"),
        Row(setting: .auto, inputs: plugged(), reason: nil, label: "plugged in"),
        // auto, Low Power Mode: on plugged in too, and the reason over battery and heat.
        Row(setting: .auto, inputs: plugged(lowPowerMode: true), reason: .lowPowerMode, label: "plugged in, Low Power Mode"),
        Row(setting: .auto, inputs: desktop(lowPowerMode: true), reason: .lowPowerMode, label: "desktop, Low Power Mode"),
        Row(setting: .auto, inputs: battery(10, thermal: .critical, lowPowerMode: true), reason: .lowPowerMode,
            label: "battery 10%, critical, Low Power Mode"),
        // auto, thermal: serious or critical on battery only; never plugged in or on a desktop.
        Row(setting: .auto, inputs: battery(80, thermal: .serious), reason: .thermal, label: "battery 80%, serious"),
        Row(setting: .auto, inputs: battery(80, thermal: .critical), reason: .thermal, label: "battery 80%, critical"),
        Row(setting: .auto, inputs: battery(80, thermal: .fair), reason: nil, label: "battery 80%, fair"),
        Row(setting: .auto, inputs: plugged(thermal: .critical), reason: nil, label: "plugged in, critical"),
        Row(setting: .auto, inputs: plugged(thermal: .serious), reason: nil, label: "plugged in, serious"),
        Row(setting: .auto, inputs: desktop(thermal: .critical), reason: nil, label: "desktop, critical"),
        // A low battery is the reason over heat.
        Row(setting: .auto, inputs: battery(10, thermal: .serious), reason: .battery, label: "battery 10%, serious"),
        // An unknown charge never counts as low.
        Row(setting: .auto, inputs: EnergyInputs(onBattery: true, hasBattery: true), reason: nil, label: "battery, unknown charge"),
    ]

    @Test(arguments: table)
    func eachModeDecides(row: Row) {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: row.setting, inputs: row.inputs) == row.reason)
        #expect(resolver.reason(setting: row.setting, inputs: row.inputs) == row.reason)
    }

    @Test func everyModeHasRows() {
        #expect(Set(Self.table.map(\.setting)) == Set(EnergySaverMode.allCases))
    }

    @Test func theFeatureOffKeepsTheSaverOff() {
        var resolver = EnergyPolicyResolver(isEnabled: false)
        for row in Self.table {
            #expect(resolver.update(setting: row.setting, inputs: row.inputs) == nil, "\(row.testDescription)")
        }
    }

    /// A Mac on battery that moves between fair and serious under load turns the saver on once: the
    /// thermal reason holds until it cools to nominal or is plugged in.
    @Test func theThermalReasonHoldsUntilNominal() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .fair)) == nil, "fair alone is no reason")
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .serious)) == .thermal)
        for thermal in [ProcessInfo.ThermalState.fair, .serious, .fair, .critical, .fair] {
            #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: thermal)) == .thermal,
                    "the saver flapped off at \(thermal.rawValue)")
            #expect(resolver.reason(setting: .auto, inputs: Self.battery(80, thermal: thermal)) == .thermal)
        }
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .nominal)) == nil, "cooled to nominal")
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .fair)) == nil, "the hold outlived nominal")
        // Plugged in ends the hold too: back on battery at fair, the saver stays off.
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .serious)) == .thermal)
        #expect(resolver.update(setting: .auto, inputs: Self.plugged(thermal: .fair)) == nil)
        #expect(resolver.update(setting: .auto, inputs: Self.battery(80, thermal: .fair)) == nil, "the hold outlived the plug-in")
    }

    @Test func theThresholdIsChromes() {
        #expect(EnergyPolicyResolver.lowBatteryThresholdPercent == 20)
    }

    @Test func turnOffForNowHoldsUntilPluggedIn() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: .auto, inputs: Self.battery(10)) == .battery)
        resolver.turnOffForNow()
        #expect(resolver.isOffForSession)
        // It holds while the battery drains, the Mac heats up or Low Power Mode comes on.
        #expect(resolver.update(setting: .auto, inputs: Self.battery(5)) == nil)
        #expect(resolver.update(setting: .auto, inputs: Self.battery(5, thermal: .critical, lowPowerMode: true)) == nil)
        // The battery -> AC edge ends it; Low Power Mode, still on, turns the saver back on.
        #expect(resolver.update(setting: .auto, inputs: Self.plugged(lowPowerMode: true)) == .lowPowerMode)
        #expect(!resolver.isOffForSession)
        // Back on battery, low: the saver is on again.
        #expect(resolver.update(setting: .auto, inputs: Self.battery(5)) == .battery)
    }

    @Test func turnOffForNowEndsOnASettingChange() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: .always, inputs: Self.plugged()) == .setting)
        resolver.turnOffForNow()
        #expect(resolver.update(setting: .always, inputs: Self.plugged()) == nil)
        // Plugged in all along: no battery edge. The setting change alone ends it.
        #expect(resolver.update(setting: .auto, inputs: Self.plugged(lowPowerMode: true)) == .lowPowerMode)
        #expect(!resolver.isOffForSession)
    }

    @Test func noEdgeKeepsItOff() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: .always, inputs: Self.plugged()) == .setting)
        resolver.turnOffForNow()
        // Plugged in throughout, heat changing: no edge.
        #expect(resolver.update(setting: .always, inputs: Self.plugged(thermal: .serious)) == nil)
        // AC -> battery is not the edge either.
        #expect(resolver.update(setting: .always, inputs: Self.battery(90)) == nil)
        #expect(resolver.isOffForSession)
    }

    /// The edge is the Mac's own power source (`macOnBattery`): a `debug.energy.simulate` battery that goes
    /// away is no plug-in, and a real plug-in under a simulated battery still is.
    @Test func onlyTheMacsOwnPlugInIsTheEdge() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        _ = resolver.update(setting: .auto, inputs: Self.plugged())
        resolver.turnOffForNow()
        let simulatedBattery = EnergyInputs(onBattery: true, macOnBattery: false, hasBattery: true, batteryPercent: 15)
        #expect(resolver.update(setting: .auto, inputs: simulatedBattery) == nil)
        #expect(resolver.update(setting: .auto, inputs: Self.plugged()) == nil)
        #expect(resolver.isOffForSession, "a simulated battery that goes away is no plug-in")
        #expect(resolver.update(setting: .auto, inputs: Self.battery(50)) == nil)
        #expect(resolver.update(setting: .auto, inputs: simulatedBattery) == .battery)
        #expect(!resolver.isOffForSession, "the Mac was plugged in under the simulated battery")
    }

    @Test func turnOffForNowBeforeAnyInputsWaitsForAnEdge() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        resolver.turnOffForNow()
        // The first inputs set the baseline; they are no setting change.
        #expect(resolver.update(setting: .always, inputs: Self.plugged()) == nil)
        #expect(resolver.isOffForSession)
    }

    @Test func turnOnNowEndsItBeforeTheEdge() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        #expect(resolver.update(setting: .auto, inputs: Self.battery(10)) == .battery)
        resolver.turnOffForNow()
        #expect(resolver.update(setting: .auto, inputs: Self.battery(10)) == nil)
        resolver.turnOnNow()
        #expect(resolver.update(setting: .auto, inputs: Self.battery(10)) == .battery)
    }

    @Test func theReasonBuildsThePolicy() {
        var resolver = EnergyPolicyResolver(isEnabled: true)
        let saver = EnergyPolicy(saverReason: resolver.update(setting: .auto, inputs: Self.battery(10)), onBattery: true)
        #expect(saver.isSaver && saver.reason == .battery)
        let normal = EnergyPolicy(saverReason: resolver.update(setting: .auto, inputs: Self.plugged()))
        #expect(!normal.isSaver && normal.reason == nil)
    }
}

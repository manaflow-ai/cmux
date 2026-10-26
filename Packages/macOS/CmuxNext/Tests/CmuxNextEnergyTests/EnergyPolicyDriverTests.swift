import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// The setting and the power inputs reach the app's one ``EnergyPolicySource`` through the driver
/// (p14-energy-024): nothing before both are known, then each change of either re-resolves.
@MainActor
struct EnergyPolicyDriverTests {
    static let lowBattery = EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 10)
    static let plugged = EnergyInputs(onBattery: false, hasBattery: true)

    @Test func publishesNothingUntilTheSettingAndTheInputsAreKnown() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        driver.update(inputs: EnergyInputs(lowPowerMode: true, onBattery: true, hasBattery: true, batteryPercent: 80))
        #expect(source.policy == .normal, "the setting is not read yet: Low Power Mode must not turn the saver on before it")
        driver.update(setting: .off)
        #expect(source.policy == EnergyPolicy(onBattery: true))
    }

    /// `debug.energy`'s `session_override` reads the driver's resolver: "Turn Off for Now" is not
    /// held at launch, nor after the setting and the inputs arrive.
    @Test func turnOffForNowIsNotHeldAtLaunch() {
        let driver = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: true)
        #expect(!driver.isOffForSession)
        driver.update(setting: .auto)
        driver.update(inputs: Self.lowBattery)
        #expect(!driver.isOffForSession)
    }

    @Test func inputsDriveTheSaverInAuto() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        driver.update(setting: .auto)
        driver.update(inputs: Self.plugged)
        #expect(source.policy == .normal)
        driver.update(inputs: Self.lowBattery)
        #expect(source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
        #expect(source.policy.wakeAlignment == WakeLeeway.saverAlignment)
        driver.update(inputs: Self.plugged)
        #expect(source.policy == .normal)
    }

    @Test func aSettingChangeReResolvesWithTheLastInputs() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        driver.update(setting: .auto)
        driver.update(inputs: Self.plugged)
        driver.update(setting: .always)
        #expect(source.policy == EnergyPolicy(saverReason: .setting))
        driver.update(setting: .onBattery)
        #expect(source.policy == .normal)
        driver.update(inputs: EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 90))
        #expect(source.policy == EnergyPolicy(saverReason: .setting, onBattery: true))
    }

    @Test func theFeatureOffKeepsTheSaverOffButStillPublishesThePowerSource() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: false)
        driver.update(setting: .always)
        driver.update(inputs: Self.lowBattery)
        #expect(source.policy == EnergyPolicy(onBattery: true))
        #expect(!source.policy.isSaver)
    }

    @Test func observersHearEachResolvedChangeOnce() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        let heard = Heard()
        let observation = source.observe { policy in MainActor.assumeIsolated { heard.policies.append(policy) } }
        driver.update(setting: .auto)
        driver.update(inputs: Self.lowBattery)
        driver.update(inputs: EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 9))  // same policy
        driver.update(setting: .off)
        #expect(heard.policies == [EnergyPolicy(saverReason: .battery, onBattery: true), EnergyPolicy(onBattery: true)])
        observation.cancel()
    }

    @MainActor
    final class Heard {
        var policies: [EnergyPolicy] = []
    }
}

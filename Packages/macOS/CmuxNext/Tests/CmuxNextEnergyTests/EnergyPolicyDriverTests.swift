import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// The setting and the power inputs reach the app's one ``EnergyPolicySource`` through the driver:
/// nothing before both are known, then each change of either re-resolves.
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

    /// `energySaver` is a `both` feature: with a local daemon its session value waits for
    /// the daemon's answer, so nothing publishes with the app's launch value first, and the value never flips.
    @Test func anUnknownFeaturePublishesNothingUntilTheSessionValueAndNeverFlips() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: nil)
        driver.update(setting: .always)
        driver.update(inputs: Self.lowBattery)
        #expect(source.policy == .normal, "published before the session's energySaver value was known")
        #expect(!driver.isEnabled)
        driver.resolveFeature(isEnabled: false)  // the daemon kept energySaver off
        #expect(source.policy == EnergyPolicy(onBattery: true))
        #expect(!source.policy.isSaver)
        driver.resolveFeature(isEnabled: true)
        driver.update(inputs: Self.lowBattery)
        #expect(!driver.isEnabled && !source.policy.isSaver, "the feature flipped in the session")
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

    /// With the feature off the setting decides nothing: the inputs alone publish, and Low Power Mode
    /// reaches the page consumers as the fallback, never as the saver.
    @Test func theFeatureOffCarriesLowPowerModeAsTheFallback() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: false)
        driver.update(inputs: EnergyInputs(lowPowerMode: true))
        #expect(source.policy == EnergyPolicy(lowPowerFallback: true), "the fallback waited for the setting")
        #expect(source.policy.pageSaver && !source.policy.isSaver)
        driver.update(setting: .off)
        #expect(source.policy.pageSaver, "energy.saver off dropped the fallback while the feature is off")
        driver.update(inputs: EnergyInputs())
        #expect(source.policy == .normal)
    }

    /// With the feature on, Low Power Mode works only through the saver: `energy.saver` off keeps
    /// pages at full speed, `auto` turns the saver on for it.
    @Test func theFeatureOnHasNoFallback() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        driver.update(setting: .off)
        driver.update(inputs: EnergyInputs(lowPowerMode: true))
        #expect(!source.policy.pageSaver && !source.policy.lowPowerFallback)
        driver.update(setting: .auto)
        #expect(source.policy == EnergyPolicy(saverReason: .lowPowerMode))
        #expect(source.policy.pageSaver)
    }

    /// A Mac on battery moving between fair and serious publishes one saver edge, not one per move.
    @Test func aFlappingThermalStatePublishesOneSaverEdge() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        let heard = Heard()
        let observation = source.observe { policy in MainActor.assumeIsolated { heard.policies.append(policy) } }
        driver.update(setting: .auto)
        for thermal in [ProcessInfo.ThermalState.fair, .serious, .fair, .serious, .fair, .critical, .fair] {
            driver.update(inputs: EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 80, thermal: thermal))
        }
        #expect(heard.policies == [EnergyPolicy(onBattery: true), EnergyPolicy(saverReason: .thermal, onBattery: true)])
        observation.cancel()
    }

    /// debug.energy reports the feature and "Turn Off for Now" from the driver's resolver, the one that
    /// decides the policy.
    @Test func reportsTheResolversFeatureAndSessionOverride() {
        let off = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: false)
        #expect(!off.isEnabled)
        #expect(!off.isOffForSession)
        let on = EnergyPolicyDriver(source: EnergyPolicySource(), isEnabled: true)
        on.update(setting: .always)
        on.update(inputs: Self.plugged)
        #expect(on.isEnabled)
        #expect(!on.isOffForSession, "nothing turned the saver off for this session")
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

    /// "Turn Off for Now" and "Turn On Again" publish at once, and a later input with
    /// no battery -> AC edge keeps the hold.
    @Test func turnOffForNowPublishesAtOnceAndTurnOnNowEndsIt() {
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: true)
        driver.update(setting: .auto)
        driver.update(inputs: Self.lowBattery)
        driver.turnOffForNow()
        #expect(driver.isOffForSession)
        #expect(source.policy == EnergyPolicy(onBattery: true, offForNow: true))
        driver.update(inputs: EnergyInputs(onBattery: true, hasBattery: true, batteryPercent: 8))
        #expect(source.policy == EnergyPolicy(onBattery: true, offForNow: true), "still on battery: the hold stays")
        driver.turnOnNow()
        #expect(!driver.isOffForSession)
        #expect(source.policy == EnergyPolicy(saverReason: .battery, onBattery: true))
    }

    @MainActor
    final class Heard {
        var policies: [EnergyPolicy] = []
    }
}

import CmuxNextDaemonService
import CmuxNextEnergy
import CmuxNextKeepAwake
import CmuxNextWakeups

/// The energy policy's pushed consumers (``EnergyHostLink`` calls these on each change).
extension AppServices: EnergyHost {
    func energyPolicyDidChange(_ policy: EnergyPolicy) { daemon.sendEnergy(policy) }
    func onBatteryDidChange(_ onBattery: Bool) { KeepAwakeService.shared.setOnBattery(onBattery) }
}

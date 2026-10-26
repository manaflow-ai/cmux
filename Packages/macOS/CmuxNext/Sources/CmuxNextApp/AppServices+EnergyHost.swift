import CmuxNextDaemonService
import CmuxNextEnergy
import CmuxNextWakeups

/// The energy policy's pushed consumers (``EnergyHostLink`` calls these on each edge).
extension AppServices: EnergyHost {
    func energySaverDidChange(_ policy: EnergyPolicy) { daemon.setEnergy(policy) }
    func onBatteryDidChange(_ onBattery: Bool) { keepAwakeOnBattery?(onBattery) }
}

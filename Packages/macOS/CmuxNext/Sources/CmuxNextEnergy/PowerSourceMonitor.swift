import Foundation
import IOKit.ps

/// Whether this Mac runs on battery, and a callback when the power source
/// changes: IOKit's power-source notification on the main run loop, so
/// nothing polls. The app's one IOKit power-source run-loop source;
/// ``EnergyMonitor`` starts it once, and only on a Mac with a battery.
final class PowerSourceMonitor {
    /// Called on the main actor after each power-source change (the source, a charge step).
    var onChange: (@MainActor () -> Void)?
    private var source: CFRunLoopSource?

    /// Starts listening; a second call does nothing.
    func start() {
        guard source == nil else { return }
        // The source holds the monitor (a retained context) for as long as it is registered, the
        // app's lifetime, so a callback never finds it gone.
        let context = Unmanaged.passRetained(self).toOpaque()
        let made = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            // task-owner: one main-actor hop per power-source change (a rare event)
            Task { @MainActor in monitor.onChange?() }
        }, context)?.takeRetainedValue()
        guard let made else {
            Unmanaged<PowerSourceMonitor>.fromOpaque(context).release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .commonModes)
        source = made
    }

    /// True when the battery provides power; false on adapter power, a UPS
    /// counted as AC, and a Mac with no battery.
    nonisolated static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

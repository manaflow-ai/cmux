import Foundation
import IOKit.ps

/// Whether this Mac runs on battery, and a callback when the power source
/// changes: IOKit's power-source notification on the main run loop, so
/// nothing polls.
final class PowerSourceMonitor {
    /// Called on the main thread with the new battery state.
    var onChange: ((Bool) -> Void)?
    private var source: CFRunLoopSource?

    /// Starts listening (once) and returns whether the Mac runs on battery now.
    func start() -> Bool {
        if source == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            // The monitor lives as long as `KeepAwakeService.shared`, the app's lifetime,
            // so the unretained context never dangles.
            let made = IOPSNotificationCreateRunLoopSource({ context in
                guard let context, Thread.isMainThread else { return }
                let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.onChange?(PowerSourceMonitor.onBattery()) }
            }, context)?.takeRetainedValue()
            if let made {
                CFRunLoopAddSource(CFRunLoopGetMain(), made, .commonModes)
                source = made
            }
        }
        return Self.onBattery()
    }

    /// True when the battery provides power; false on adapter power, a UPS
    /// counted as AC, and a Mac with no battery.
    nonisolated static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

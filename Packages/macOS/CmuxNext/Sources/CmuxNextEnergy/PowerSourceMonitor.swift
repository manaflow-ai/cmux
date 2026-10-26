import Foundation
import IOKit.ps

/// A callback when the power source changes: IOKit's power-source notification on the main run
/// loop, so nothing polls. The app's one IOKit power-source run-loop source; ``EnergyMonitor``
/// starts it once, only on a Mac with a battery.
final class PowerSourceMonitor {
    /// Called on the main actor after each power-source change (the source, a charge step).
    var onChange: (@MainActor () -> Void)?
    private var registration: Registration?

    /// The run-loop source and what its context points to. The context holds one retain on the
    /// registration, which ``end()`` gives back; the registration holds the monitor weakly, so the
    /// source never keeps the monitor alive, and the first change after the monitor went ends it.
    /// The callback, ``end()`` and ``stop()`` all run on the main thread, so none reads a released context.
    private final class Registration {
        weak var monitor: PowerSourceMonitor?
        var source: CFRunLoopSource?

        init(_ monitor: PowerSourceMonitor) { self.monitor = monitor }

        func fire() {
            guard source != nil else { return }  // a change already queued when it ended
            guard let monitor else { return end() }
            monitor.onChange?()
        }

        /// Removes the source and gives back the context's retain; a second call does nothing.
        func end() {
            guard let source else { return }
            CFRunLoopSourceInvalidate(source)
            self.source = nil
            Unmanaged.passUnretained(self).release()
        }
    }

    /// Starts listening; a second call does nothing.
    func start() {
        guard registration == nil else { return }
        let registration = Registration(self)
        let context = Unmanaged.passRetained(registration).toOpaque()
        let made = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let registration = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
            // task-owner: one main-actor hop per power-source change (a rare event)
            Task { @MainActor in registration.fire() }
        }, context)?.takeRetainedValue()
        guard let made else { return Unmanaged<Registration>.fromOpaque(context).release() }
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .commonModes)
        registration.source = made
        self.registration = registration
    }

    /// Removes the run-loop source; ``start()`` may run again.
    func stop() {
        registration?.end()
        registration = nil
    }

    /// The power source now, from one IOKit snapshot (one IPC to powerd): whether the battery
    /// provides power (false on adapter power, a UPS counted as AC, and a Mac with no battery) and
    /// the internal battery.
    nonisolated static func read() -> PowerSourceReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerSourceReading() }
        let type = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }
        let battery = BatteryLevel(info: info)
        return PowerSourceReading(onBattery: type == kIOPMBatteryPowerKey, hasBattery: battery.hasBattery,
                                  batteryPercent: battery.percent)
    }
}

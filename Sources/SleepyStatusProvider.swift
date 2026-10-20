import CoreWLAN
import Foundation
import IOKit.ps

/// Samples battery + wifi at most every few seconds (reads are cheap but not
/// worth doing every frame). `@MainActor`-isolated: sampled from the renderer's
/// TimelineView body on the main actor, so the cache has enforced isolation
/// rather than `nonisolated(unsafe)` + convention.
@MainActor
final class SleepyStatusProvider: SleepyStatusProviding {
    private var cached = SleepyStatusSample(batteryLevel: nil, charging: false, wifiBars: nil)
    private var lastSample: Double = -100
    private let interval: Double = 4

    func sample(at time: Double) -> SleepyStatusSample {
        if time - lastSample >= interval {
            lastSample = time
            cached = SleepyStatusSample(
                batteryLevel: Self.readBattery()?.level,
                charging: Self.readBattery()?.charging ?? false,
                wifiBars: Self.readWifiBars()
            )
        }
        return cached
    }

    private static func readBattery() -> (level: Double, charging: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let maximum = desc[kIOPSMaxCapacityKey as String] as? Int, maximum > 0
            else { continue }
            let charging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            return (min(1, max(0, Double(current) / Double(maximum))), charging)
        }
        return nil
    }

    private static func readWifiBars() -> Int? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let rssi = interface.rssiValue()
        guard rssi != 0 else { return nil }
        switch rssi {
        case ..<(-80): return 1
        case ..<(-70): return 2
        case ..<(-60): return 3
        default: return 4
        }
    }
}

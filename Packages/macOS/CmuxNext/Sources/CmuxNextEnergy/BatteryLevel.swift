import Foundation
import IOKit.ps

/// The Mac's internal battery as IOKit's power-source API reports it: whether there is one, and
/// its charge. Chrome reads the same IOPS descriptions for its battery saver's level
/// (services/device/battery/battery_status_manager_mac.cc, `GetInternalBatteryInfo`).
nonisolated struct BatteryLevel: Equatable, Sendable {
    /// This Mac has an internal battery (false on a Mac mini, Studio or Pro).
    var hasBattery: Bool
    /// The charge in percent of the full capacity, 0 to 100; nil without a battery or a capacity.
    var percent: Int?

    /// No battery.
    init() {
        hasBattery = false
        percent = nil
    }

    /// The first internal battery among `descriptions` (IOPS power source description dictionaries).
    init(descriptions: [[String: Any]]) {
        self.init()
        guard let battery = descriptions.first(where: { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }) else {
            return
        }
        hasBattery = true
        percent = Self.percent(current: battery[kIOPSCurrentCapacityKey] as? Int, full: battery[kIOPSMaxCapacityKey] as? Int)
    }

    /// `current` as a share of `full`, rounded and clamped to 0...100; nil when either is missing or `full` is 0.
    static func percent(current: Int?, full: Int?) -> Int? {
        guard let current, let full, full > 0 else { return nil }
        let share = (Double(current) * 100 / Double(full)).rounded()
        return min(max(Int(share), 0), 100)
    }

    /// The internal battery in `info`, one `IOPSCopyPowerSourcesInfo` snapshot.
    init(info: CFTypeRef) {
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        self.init(descriptions: list.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        })
    }
}

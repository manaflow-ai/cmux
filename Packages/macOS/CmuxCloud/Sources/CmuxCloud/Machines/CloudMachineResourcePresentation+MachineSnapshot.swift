import Foundation
import CmuxCloudMachines

extension CloudMachineResourcePresentation {
    /// Maps the app's immutable machine snapshot to the package's resource presentation.
    public init(machine: MachineSnapshot, now: Date = .now) {
        let stats = machine.stats
        self.init(
            availability: Self.availability(machine: machine, now: now),
            cpuPercent: stats?.cpuPercent,
            cpus: stats?.cpus,
            memoryUsedMb: stats?.memoryUsedMb,
            memoryTotalMb: stats?.memoryTotalMb,
            diskUsedMb: stats?.diskUsedMb,
            diskTotalMb: stats?.diskTotalMb
        )
    }

    /// Resolves sample freshness without constructing any localized readings.
    /// - Parameters:
    ///   - machine: The immutable machine and its latest telemetry.
    ///   - now: The time at which the readings will be presented.
    /// - Returns: The availability shared by all three resource readings.
    public static func availability(machine: MachineSnapshot, now: Date) -> Availability {
        let stats = machine.stats
        let availability: Availability
        if !machine.capabilities.stats {
            availability = .unavailable
        } else if stats == nil {
            availability = .loading
        } else {
            switch stats!.state {
            case .asleep:
                availability = .asleep
            case .unknown:
                availability = .unavailable
            case .awake:
                guard let sampledAt = stats!.resourceSampledAt, sampledAt <= now else {
                    availability = .unavailable
                    break
                }
                if now.timeIntervalSince(sampledAt) > Self.staleSampleAge {
                    availability = .stale
                } else {
                    availability = .awake
                }
            }
        }
        return availability
    }
}

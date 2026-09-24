import Foundation
import CmuxCloudMachines

extension CloudMachineResourcePresentation {
    /// Maps the app's immutable machine snapshot to the package's resource presentation.
    init(machine: MachineSnapshot, now: Date = .now) {
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
        self.init(
            availability: availability,
            cpuPercent: stats?.cpuPercent,
            cpus: stats?.cpus,
            memoryUsedMb: stats?.memoryUsedMb,
            memoryTotalMb: stats?.memoryTotalMb,
            diskUsedMb: stats?.diskUsedMb,
            diskTotalMb: stats?.diskTotalMb
        )
    }
}

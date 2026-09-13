import CmuxCloudMachines

extension CloudMachineResourcePresentation {
    /// Maps the app's immutable machine snapshot to the package's resource presentation.
    init(machine: MachineSnapshot) {
        let stats = machine.stats
        let availability: Availability = machine.capabilities.stats && stats?.state == .awake
            ? .awake : stats?.state == .asleep ? .asleep : .unavailable
        self.init(
            availability: availability,
            cpuPercent: stats?.cpuPercent,
            memoryUsedMb: stats?.memoryUsedMb,
            memoryTotalMb: stats?.memoryTotalMb,
            diskUsedMb: stats?.diskUsedMb,
            diskTotalMb: stats?.diskTotalMb
        )
    }
}

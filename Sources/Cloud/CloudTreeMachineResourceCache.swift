import CmuxCloud
import CmuxCloudMachines
import Foundation

/// One bounded generation of formatted readings, shared across rows and machines.
@MainActor
final class CloudTreeMachineResourceCache {
    private struct Key: Hashable {
        let availability: CloudMachineResourcePresentation.Availability
        let cpu: Double?
        let cpus: Int?
        let memoryUsed: Int?
        let memoryTotal: Int?
        let diskUsed: Int?
        let diskTotal: Int?
        let tokens: Int?
        let cost: Double?
        let periodDays: Int?

        init(machine: MachineSnapshot, now: Date) {
            availability = CloudMachineResourcePresentation.availability(machine: machine, now: now)
            cpu = machine.stats?.cpuPercent
            cpus = machine.stats?.cpus
            memoryUsed = machine.stats?.memoryUsedMb
            memoryTotal = machine.stats?.memoryTotalMb
            diskUsed = machine.stats?.diskUsedMb
            diskTotal = machine.stats?.diskTotalMb
            tokens = machine.usage?.totals.totalTokens
            cost = machine.usage?.totals.apiEquivalentUsd
            periodDays = machine.usage?.periodDays
        }
    }

    private var sections: [Key: CloudTreeMachineResourceSection] = [:]
    private var used: Set<Key> = []
    private var locale: String?
    private let makeSection: (MachineSnapshot, Date) -> CloudTreeMachineResourceSection

    init(makeSection: @escaping (MachineSnapshot, Date) -> CloudTreeMachineResourceSection = {
        CloudTreeMachineResourceSection(machine: $0, now: $1)
    }) {
        self.makeSection = makeSection
    }

    func beginBuild(locale: String) {
        if self.locale != locale { sections.removeAll(); self.locale = locale }
        used.removeAll(keepingCapacity: true)
    }

    func section(machine: MachineSnapshot, now: Date) -> CloudTreeMachineResourceSection {
        let key = Key(machine: machine, now: now)
        used.insert(key)
        if let section = sections[key] { return section }
        let section = makeSection(machine, now)
        sections[key] = section
        return section
    }

    func endBuild() {
        sections = sections.filter { used.contains($0.key) }
    }
}

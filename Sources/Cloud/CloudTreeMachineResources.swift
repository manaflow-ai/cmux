import Foundation

/// Pure presentation of the latest stats snapshot, shared by the row and its tooltip.
struct CloudTreeMachineResources {
    struct Reading {
        let label: String
        let percent: Double?
        let detail: String

        var value: String {
            guard let percent else {
                return String(localized: "cloudTree.resources.missing", defaultValue: "—")
            }
            return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    let cpu: Reading
    let memory: Reading
    let disk: Reading

    var summary: String { [cpu.detail, memory.detail, disk.detail].joined(separator: "\n") }

    init(machine: MachineSnapshot) {
        let stats = machine.stats
        let available = machine.capabilities.stats && stats?.state == .awake
        let unavailable = stats?.state == .asleep
            ? String(localized: "cloudTree.resources.asleep", defaultValue: "Asleep")
            : String(localized: "cloudTree.resources.unavailable", defaultValue: "Unavailable")
        let cpuLabel = String(localized: "machines.stats.cpu", defaultValue: "CPU")
        let cpuPercent = available ? stats?.cpuPercent.flatMap(Self.validCPU) : nil
        cpu = Reading(
            label: cpuLabel,
            percent: cpuPercent,
            detail: cpuPercent.map {
                String(format: String(localized: "cloudTree.stats.cpu", defaultValue: "CPU %d%%"), Int($0.rounded()))
            } ?? "\(cpuLabel): \(unavailable)"
        )
        memory = Self.capacity(
            label: String(localized: "cloudTree.resources.ram", defaultValue: "RAM"),
            used: available ? stats?.memoryUsedMb : nil,
            total: available ? stats?.memoryTotalMb : nil,
            format: String(localized: "cloudTree.stats.memory", defaultValue: "Mem %@/%@ GB"),
            unavailable: unavailable
        )
        disk = Self.capacity(
            label: String(localized: "machines.stats.disk", defaultValue: "Disk"),
            used: available ? stats?.diskUsedMb : nil,
            total: available ? stats?.diskTotalMb : nil,
            format: String(localized: "cloudTree.stats.disk", defaultValue: "Disk %@/%@ GB"),
            unavailable: unavailable
        )
    }

    private static func validCPU(_ percent: Double) -> Double? {
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent
    }

    private static func capacity(label: String, used: Int?, total: Int?, format: String, unavailable: String) -> Reading {
        guard let used, let total, used >= 0, total > 0 else {
            return Reading(label: label, percent: nil, detail: "\(label): \(unavailable)")
        }
        // Separate OS counters may straddle an update. Keep the percentage within capacity
        // while preserving the actual reported amounts in the detail.
        let percent = min(100, Double(used) / Double(total) * 100)
        let value = Reading(label: label, percent: percent, detail: "").value
        return Reading(
            label: label,
            percent: percent,
            detail: "\(String(format: format, gb(used), gb(total))) (\(value))"
        )
    }

    private static func gb(_ mb: Int) -> String {
        (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...1)))
    }
}

import Foundation

/// Pure presentation of the latest stats snapshot, shared by the row and its tooltip.
public struct CloudMachineResourcePresentation: Sendable {
    /// Whether the latest sample can be presented as live usage.
    public enum Availability: Equatable, Sendable {
        /// The machine is awake and supports resource statistics.
        case awake
        /// The machine is sleeping, so prior readings are unavailable.
        case asleep
        /// A supported, current sample is not available.
        case unavailable
    }

    /// One localized resource label, optional percentage, and accessible detail.
    public struct Reading: Sendable {
        /// The localized name of this resource.
        public let label: String
        /// A validated utilization percentage, or nil for an unavailable reading.
        public let percent: Double?
        /// Localized detail suitable for a tooltip or accessibility label.
        public let detail: String

        /// A whole percentage or the localized missing-value placeholder.
        public var value: String {
            guard let percent else {
                return String(localized: "cloudTree.resources.missing", defaultValue: "—")
            }
            return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    /// Current CPU utilization.
    public let cpu: Reading
    /// Current memory utilization and reported capacity.
    public let memory: Reading
    /// Current root disk utilization and reported capacity.
    public let disk: Reading

    /// The three resource details in display order, separated by newlines.
    public var summary: String { [cpu.detail, memory.detail, disk.detail].joined(separator: "\n") }

    /// Presents advisory resource readings without depending on app or provider types.
    ///
    /// Localized text uses the host application's string catalog.
    ///
    /// ```swift
    /// let resources = CloudMachineResourcePresentation(availability: .awake, cpuPercent: 25)
    /// // resources.cpu.percent == 25
    /// ```
    ///
    /// - Parameters:
    ///   - availability: Whether the sample is live, sleeping, or unavailable.
    ///   - cpuPercent: CPU utilization in the inclusive range 0 through 100.
    ///   - memoryUsedMb: Used memory in MiB, when sampled.
    ///   - memoryTotalMb: Provisioned memory in MiB, when known.
    ///   - diskUsedMb: Used root filesystem space in MiB, when sampled.
    ///   - diskTotalMb: Root filesystem capacity in MiB, when known.
    public init(
        availability: Availability,
        cpuPercent: Double? = nil,
        memoryUsedMb: Int? = nil,
        memoryTotalMb: Int? = nil,
        diskUsedMb: Int? = nil,
        diskTotalMb: Int? = nil
    ) {
        let available = availability == .awake
        let unavailable = availability == .asleep
            ? String(localized: "cloudTree.resources.asleep", defaultValue: "Asleep")
            : String(localized: "cloudTree.resources.unavailable", defaultValue: "Unavailable")
        let cpuLabel = String(localized: "machines.stats.cpu", defaultValue: "CPU")
        let cpuPercent = available ? cpuPercent.flatMap(Self.validCPU) : nil
        cpu = Reading(
            label: cpuLabel,
            percent: cpuPercent,
            detail: cpuPercent.map {
                String(format: String(localized: "cloudTree.stats.cpu", defaultValue: "CPU %d%%"), Int($0.rounded()))
            } ?? "\(cpuLabel): \(unavailable)"
        )
        memory = Self.capacity(
            label: String(localized: "cloudTree.resources.ram", defaultValue: "RAM"),
            used: available ? memoryUsedMb : nil,
            total: available ? memoryTotalMb : nil,
            format: String(localized: "cloudTree.stats.memory", defaultValue: "Mem %@/%@ GB"),
            unavailable: unavailable
        )
        disk = Self.capacity(
            label: String(localized: "machines.stats.disk", defaultValue: "Disk"),
            used: available ? diskUsedMb : nil,
            total: available ? diskTotalMb : nil,
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

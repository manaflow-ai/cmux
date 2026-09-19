import Foundation

private func validCPU(_ percent: Double) -> Double? {
    guard percent.isFinite, (0...100).contains(percent) else { return nil }
    return percent
}

private func capacity(
    label: String,
    used: Int?,
    total: Int?,
    format: String,
    unavailable: String,
    placeholder: String
) -> CloudMachineResourcePresentation.Reading {
    guard let used, let total, used >= 0, total > 0 else {
        return .init(label: label, percent: nil, detail: "\(label): \(unavailable)", inlineDetail: unavailable, placeholder: placeholder)
    }
    // Separate OS counters may straddle an update. Keep the percentage within capacity
    // while preserving the actual reported amounts in the detail.
    let percent = min(100, Double(used) / Double(total) * 100)
    let value = (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    let capacity = String(
        format: String(localized: "machines.stats.provisioned", defaultValue: "%@ GB"),
        "\(gb(used))/\(gb(total))"
    )
    return .init(
        label: label,
        percent: percent,
        detail: "\(String(format: format, gb(used), gb(total))) (\(value))",
        inlineDetail: "\(capacity) (\(value))",
        placeholder: placeholder
    )
}

private func gb(_ mb: Int) -> String {
    (Double(mb) / 1024).formatted(.number.precision(.fractionLength(0...1)))
}

/// Pure presentation of the latest stats snapshot, shared by the row and its tooltip.
public struct CloudMachineResourcePresentation: Equatable, Sendable {
    /// Whether the latest sample can be presented as live usage.
    public enum Availability: Equatable, Sendable {
        /// The machine snapshot has not received its first stats response yet.
        case loading
        /// The machine is awake and supports resource statistics.
        case awake
        /// The machine is sleeping, so prior readings are unavailable.
        case asleep
        /// A guest sample exists, but it is outside the freshness window.
        case stale
        /// A supported, current sample is not available.
        case unavailable
    }

    /// One localized resource label, optional percentage, and accessible detail.
    public struct Reading: Equatable, Sendable {
        /// The localized name of this resource.
        public let label: String
        /// A validated utilization percentage, or nil for an unavailable reading.
        public let percent: Double?
        /// Localized detail suitable for a tooltip or accessibility label.
        public let detail: String
        /// The value or availability state when the resource label is already visible.
        public let inlineDetail: String

        /// A whole percentage or a state-specific missing-value placeholder.
        public var value: String {
            guard let percent else {
                return placeholder
            }
            return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
        }

        private let placeholder: String

        fileprivate init(label: String, percent: Double?, detail: String, inlineDetail: String, placeholder: String) {
            self.label = label
            self.percent = percent
            self.detail = detail
            self.inlineDetail = inlineDetail
            self.placeholder = placeholder
        }
    }

    /// Current CPU utilization.
    public let cpu: Reading
    /// Current memory utilization and reported capacity.
    public let memory: Reading
    /// Current root disk utilization and reported capacity.
    public let disk: Reading
    /// Why the current values are present, pending, or absent.
    public let availability: Availability

    /// The server-side freshness bound for a guest resource sample.
    public static let staleSampleAge: TimeInterval = 90

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
    ///   - availability: Whether the sample is live, loading, stale, sleeping, or unavailable.
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
        self.availability = availability
        let available = availability == .awake
        let unavailable: String
        switch availability {
        case .loading:
            unavailable = String(localized: "cloudTree.resources.loading", defaultValue: "Loading")
        case .asleep:
            unavailable = String(localized: "cloudTree.resources.asleep", defaultValue: "Asleep")
        case .stale:
            unavailable = String(localized: "cloudTree.resources.stale", defaultValue: "Stale")
        case .awake, .unavailable:
            unavailable = String(localized: "cloudTree.resources.unavailable", defaultValue: "Unavailable")
        }
        let placeholder = availability == .loading
            ? String(localized: "cloudTree.resources.loading.symbol", defaultValue: "…")
            : String(localized: "cloudTree.resources.missing", defaultValue: "—")
        let cpuLabel = String(localized: "machines.stats.cpu", defaultValue: "CPU")
        let cpuPercent = available ? cpuPercent.flatMap(validCPU) : nil
        cpu = Reading(
            label: cpuLabel,
            percent: cpuPercent,
            detail: cpuPercent.map {
                String(format: String(localized: "cloudTree.stats.cpu", defaultValue: "CPU %d%%"), Int($0.rounded()))
            } ?? "\(cpuLabel): \(unavailable)",
            inlineDetail: cpuPercent.map {
                ($0 / 100).formatted(.percent.precision(.fractionLength(0)))
            } ?? unavailable,
            placeholder: placeholder
        )
        memory = capacity(
            label: String(localized: "cloudTree.resources.ram", defaultValue: "RAM"),
            used: available ? memoryUsedMb : nil,
            total: available ? memoryTotalMb : nil,
            format: String(localized: "cloudTree.stats.memory", defaultValue: "Mem %@/%@ GB"),
            unavailable: unavailable,
            placeholder: placeholder
        )
        disk = capacity(
            label: String(localized: "machines.stats.disk", defaultValue: "Disk"),
            used: available ? diskUsedMb : nil,
            total: available ? diskTotalMb : nil,
            format: String(localized: "cloudTree.stats.disk", defaultValue: "Disk %@/%@ GB"),
            unavailable: unavailable,
            placeholder: placeholder
        )
    }

}

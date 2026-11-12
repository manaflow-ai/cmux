import CmuxCloud
import Foundation
import CmuxCloudMachines

/// Immutable resource and cost data for one Cloud machine tree section.
final class CloudTreeMachineResourceSection: Equatable, Sendable {
    let metrics: CloudMachineResourcePresentation
    let usageSummary: String
    let rows: [CloudTreeMachineResourceRow]

    init(machine: MachineSnapshot, now: Date = .now) {
        metrics = CloudMachineResourcePresentation(machine: machine, now: now)
        usageSummary = CloudTreeMachineRowContent(machine: machine, style: .defaultStyle, now: now).usageSummary
        rows = [
            Self.row(metric: .cpu, title: metrics.cpu.label, detail: metrics.cpu.inlineDetail),
            Self.row(metric: .memory, title: metrics.memory.label, detail: metrics.memory.inlineDetail),
            Self.row(metric: .disk, title: metrics.disk.label, detail: metrics.disk.inlineDetail),
            Self.row(
                metric: .usage,
                title: String(localized: "cloudTree.resources.usage", defaultValue: "Usage"),
                detail: usageSummary
            ),
        ]
    }

    static func == (lhs: CloudTreeMachineResourceSection, rhs: CloudTreeMachineResourceSection) -> Bool {
        lhs === rhs || (lhs.metrics == rhs.metrics && lhs.usageSummary == rhs.usageSummary && lhs.rows == rhs.rows)
    }

    private static func row(
        metric: CloudTreeMachineResourceMetric,
        title: String,
        detail: String
    ) -> CloudTreeMachineResourceRow {
        CloudTreeMachineResourceRow(
            metric: metric,
            title: title,
            detail: detail,
            accessibilityLabel: "\(title), \(detail)"
        )
    }
}

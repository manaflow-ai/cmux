import CmuxCloud
import Foundation
import CmuxCloudMachines

/// Immutable resource and cost data for one Cloud machine tree section.
struct CloudTreeMachineResourceSection: Equatable {
    let metrics: CloudMachineResourcePresentation
    let usageSummary: String

    init(machine: MachineSnapshot, now: Date = .now) {
        metrics = CloudMachineResourcePresentation(machine: machine, now: now)
        usageSummary = CloudTreeMachineRowContent(machine: machine, now: now).usageSummary
    }

    var rows: [CloudTreeMachineResourceRow] {
        [
            row(metric: .cpu, title: metrics.cpu.label, detail: metrics.cpu.inlineDetail),
            row(metric: .memory, title: metrics.memory.label, detail: metrics.memory.inlineDetail),
            row(metric: .disk, title: metrics.disk.label, detail: metrics.disk.inlineDetail),
            row(
                metric: .usage,
                title: String(localized: "cloudTree.resources.usage", defaultValue: "Usage"),
                detail: usageSummary
            ),
        ]
    }

    private func row(
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

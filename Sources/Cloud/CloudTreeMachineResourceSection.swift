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
            row(metric: .cpu, title: metrics.cpu.label, detail: metrics.cpu.detail, icon: "cpu"),
            row(metric: .memory, title: metrics.memory.label, detail: metrics.memory.detail, icon: "memorychip"),
            row(metric: .disk, title: metrics.disk.label, detail: metrics.disk.detail, icon: "internaldrive"),
            row(
                metric: .usage,
                title: String(localized: "cloudTree.resources.usage", defaultValue: "Usage"),
                detail: usageSummary,
                icon: "chart.bar"
            ),
        ]
    }

    private func row(
        metric: CloudTreeMachineResourceRow.Metric,
        title: String,
        detail: String,
        icon: String
    ) -> CloudTreeMachineResourceRow {
        CloudTreeMachineResourceRow(
            metric: metric,
            title: title,
            detail: detail,
            icon: icon,
            accessibilityLabel: "\(title), \(detail)"
        )
    }
}

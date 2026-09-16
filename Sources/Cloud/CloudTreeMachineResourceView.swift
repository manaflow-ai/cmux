import AppKit
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// The four rows shown below a machine's Resources section.
struct CloudTreeMachineResourceRow: Equatable {
    enum Metric: String, Equatable {
        case cpu
        case memory
        case disk
        case usage
    }

    let metric: Metric
    let title: String
    let detail: String
    let icon: String
    let accessibilityLabel: String
}

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

/// A single resource or cost row inside a machine's Resources section.
struct CloudTreeMachineResourceRowContent: View {
    let row: CloudTreeMachineResourceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current

    var body: some View {
        CloudTreeLeafRow(
            style: style,
            icon: row.icon,
            tint: CloudTreeIconPalette.machine,
            title: row.title,
            detail: row.detail
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
}

/// Quiet resource text that keeps each label/value pair together when wrapping.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        CloudTreeMachineDetailView(line: line, style: style)
            .accessibilityLabel(metrics.summary)
    }

    private var line: String {
        [metrics.cpu, metrics.memory, metrics.disk]
            .map { "\($0.label)\u{00A0}\($0.value)" }
            .joined(separator: " · ")
    }

    /// AppKit reserves the same wrapping text height as the hosted SwiftUI row.
    func height(width: CGFloat, magnification: Int) -> CGFloat {
        CloudTreeMachineDetailView(line: line, style: style).height(width: width, magnification: magnification)
    }
}

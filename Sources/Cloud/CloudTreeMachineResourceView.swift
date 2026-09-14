import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Compact trailing metrics that share the machine-name baseline.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CloudTreeRowGrid.detailGap) {
            metric(metrics.cpu)
            metric(metrics.memory)
            metric(metrics.disk)
        }
        .lineLimit(1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
    }

    private func metric(_ reading: CloudMachineResourcePresentation.Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(reading.label)
                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.75)
            Text(reading.value)
                .cmuxFont(size: style.machineNameSize, weight: .semibold, design: style.fontDesign, monospacedDigit: true)
                .foregroundStyle(reading.percent == nil ? .secondary : .primary)
                .minimumScaleFactor(0.65)
        }
        .lineLimit(1)
        .layoutPriority(1)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.detail)
    }
}

import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Equal-width columns prevent changing names or readings from shifting the metrics.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        HStack(spacing: 8) {
            column(metrics.cpu)
            column(metrics.memory)
            column(metrics.disk)
        }
        .frame(height: style.machineResourceHeight)
    }

    private func column(_ reading: CloudMachineResourcePresentation.Reading) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(reading.label)
                .cmuxFont(size: style.detailSize, design: style.fontDesign)
                .foregroundStyle(.secondary)
                .frame(height: style.detailSize + 2)
            Text(reading.value)
                .cmuxFont(size: style.machineNameSize, weight: .semibold, design: style.fontDesign, monospacedDigit: true)
                .foregroundStyle(reading.percent == nil ? .secondary : .primary)
                .minimumScaleFactor(0.8)
                .frame(height: style.machineNameLineHeight)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.detail)
    }
}

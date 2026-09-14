import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// One quiet resource line below the machine name and its usage summary.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        HStack(spacing: 6) {
            reading(metrics.cpu)
            reading(metrics.memory)
            reading(metrics.disk)
        }
        .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metrics.summary)
    }

    private func reading(_ reading: CloudMachineResourcePresentation.Reading) -> some View {
        Text("\(reading.label) \(reading.value)")
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

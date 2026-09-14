import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// One quiet resource line below the machine name and its usage summary.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        Text(line)
            .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(metrics.summary)
    }

    var line: String {
        [metrics.cpu, metrics.memory, metrics.disk]
            .map { "\($0.label) \($0.value)" }
            .joined(separator: " · ")
    }
}

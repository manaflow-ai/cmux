import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// A compact text readout keeps all three resource labels visible in the narrow
/// sidebar and matches the existing token-usage treatment.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        Text(metrics.inlineSummary)
            .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: style.machineResourceHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(metrics.summary.replacingOccurrences(of: "\n", with: ", "))
    }
}

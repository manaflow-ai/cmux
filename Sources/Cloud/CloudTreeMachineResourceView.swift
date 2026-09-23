import AppKit
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Quiet resource text that keeps each label/value pair together when wrapping.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        CloudTreeMachineDetailView(line: line, style: style)
            .accessibilityLabel(metrics.summary.replacingOccurrences(of: "\n", with: ", "))
    }

    private var line: String { metrics.inlineSummary }

    /// AppKit reserves the same wrapping text height as the hosted SwiftUI row.
    func height(width: CGFloat, magnification: Int) -> CGFloat {
        CloudTreeMachineDetailView(line: line, style: style).height(width: width, magnification: magnification)
    }
}

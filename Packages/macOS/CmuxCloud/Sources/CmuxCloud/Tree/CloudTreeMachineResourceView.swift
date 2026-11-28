import AppKit
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Quiet resource text that keeps each label/value pair together when wrapping.
public struct CloudTreeMachineResourceView: View {
    public init(
        metrics: CloudMachineResourcePresentation,
        style: CloudTreeStyle
    ) {
        self.metrics = metrics
        self.style = style
    }

    public let metrics: CloudMachineResourcePresentation
    public let style: CloudTreeStyle

    public var body: some View {
        CloudTreeMachineDetailView(line: line, style: style)
            .accessibilityLabel(metrics.summary)
    }

    private var line: String {
        [metrics.cpu, metrics.memory, metrics.disk]
            .map { "\($0.label)\u{00A0}\($0.value)" }
            .joined(separator: " · ")
    }

    /// AppKit reserves the same wrapping text height as the hosted SwiftUI row.
    public func height(width: CGFloat, magnification: Int) -> CGFloat {
        CloudTreeMachineDetailView(line: line, style: style).height(width: width, magnification: magnification)
    }
}

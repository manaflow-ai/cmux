import AppKit
import CmuxCloudMachines
import CmuxFoundation
import SwiftUI

/// Quiet resource text that keeps each label/value pair together when wrapping.
struct CloudTreeMachineResourceView: View {
    let metrics: CloudMachineResourcePresentation
    let style: CloudTreeStyle

    var body: some View {
        Text(line)
            .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(metrics.summary)
    }

    private var line: String {
        [metrics.cpu, metrics.memory, metrics.disk]
            .map { "\($0.label)\u{00A0}\($0.value)" }
            .joined(separator: " · ")
    }

    /// AppKit reserves the same wrapping text height as the hosted SwiftUI row.
    func height(width: CGFloat, magnification: Int) -> CGFloat {
        let size = GlobalFontMagnification.scaledSize(style.detailSize, percent: magnification)
        let font = style.monospacedText
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let measured = NSAttributedString(string: line, attributes: [.font: font]).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return max(ceil(measured), GlobalFontMagnification.scaledSize(style.machineResourceHeight, percent: magnification))
    }
}

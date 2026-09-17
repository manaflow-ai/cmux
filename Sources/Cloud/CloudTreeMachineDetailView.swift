import AppKit
import CmuxFoundation
import SwiftUI

/// Wrapping machine details with one measurement path for both usage and resources.
struct CloudTreeMachineDetailView: View {
    let line: String
    let style: CloudTreeStyle

    var body: some View {
        Text(line)
            .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reserves every wrapped line in the AppKit outline at the current text scale.
    func height(width: CGFloat, magnification: Int) -> CGFloat {
        let size = GlobalFontMagnification.scaledSize(style.detailSize, percent: magnification)
        let font = style.monospacedText
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let measured = NSAttributedString(string: line, attributes: [.font: font]).boundingRect(
            with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        // SwiftUI rounds ascenders and descenders per line; rounding only the
        // final bounding box can leave wrapped lines a few points too short.
        let lines = max(1, (measured / (font.ascender - font.descender + font.leading)).rounded())
        let lineHeight = ceil(font.ascender) - floor(font.descender) + ceil(font.leading)
        return max(lines * lineHeight, GlobalFontMagnification.scaledSize(style.machineResourceHeight, percent: magnification))
    }
}

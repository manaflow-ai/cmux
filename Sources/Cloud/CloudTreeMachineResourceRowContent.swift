import CmuxFoundation
import SwiftUI

/// A single resource or cost row inside a machine's Resources section.
struct CloudTreeMachineResourceRowContent: View {
    let row: CloudTreeMachineResourceRow
    var style: CloudTreeStyle = CloudTreeStyleStore.current
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    var body: some View {
        HStack(spacing: scaled(style.rowGrid.detailGap)) {
            // Resource values are text-only. Starting directly in the shared
            // leading column lines them up with the icons of nested terminal,
            // Desktop, and port rows without adding a second indentation.
            Text(row.title)
                .cmuxFont(size: style.titleSize, design: style.fontDesign)
                .foregroundStyle(.primary)
                .frame(minWidth: scaled(40), alignment: .leading)
                .layoutPriority(1)
            Text(row.detail)
                .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.trailing, style.rowGrid.trailingPadding)
        .help(row.accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        GlobalFontMagnification.scaledSize(value, percent: magnification)
    }
}

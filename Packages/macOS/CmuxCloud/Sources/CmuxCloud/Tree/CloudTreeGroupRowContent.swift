import CmuxFoundation
import SwiftUI

/// Renders one Cloud tree section header and its optional count.
public struct CloudTreeGroupRowContent: View {
    public init(
        title: String,
        count: Int? = nil,
        style: CloudTreeStyle
    ) {
        self.title = title
        self.count = count
        self.style = style
    }

    public let title: String
    public let count: Int?
    public let style: CloudTreeStyle

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    public var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
            HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.detailGap) {
                Text(style.groupLabelStyle == .uppercased ? title.uppercased() : title)
                    .tracking(style.groupLabelStyle == .uppercased ? 0.8 : 0)
                    .cmuxFont(size: style.groupLabelSize, weight: .medium, design: style.fontDesign)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if style.showsGroupCounts, let count {
                    Text(String(count))
                        .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, style.rowGrid.trailingPadding)
    }
}

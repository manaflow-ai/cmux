import CmuxFoundation
import SwiftUI

/// Renders one Cloud tree section header and its optional count.
public struct CloudTreeGroupRowContent: View {
    /// Creates a section header with its display style and optional count.
    /// - Parameters:
    ///   - title: Localized section title.
    ///   - count: Count information, or nil to omit the count.
    ///   - icon: Optional section identity icon.
    ///   - iconTint: Tint for the section identity icon.
    ///   - style: Typography and spacing shared with the rest of the tree.
    public init(
        title: String,
        count: CloudTreeGroupCount? = nil,
        style: CloudTreeStyle,
        icon: String? = nil,
        iconTint: Color = .secondary
    ) {
        self.title = title
        self.count = count
        self.icon = icon
        self.iconTint = iconTint
        self.style = style
    }

    /// Localized section title.
    public let title: String
    /// Count information, omitted until the group's count is available.
    public let count: CloudTreeGroupCount?
    /// SF Symbol identifying the section, when the section has one.
    public let icon: String?
    /// Tint for ``icon``.
    public let iconTint: Color
    /// Typography and spacing shared with the rest of the tree.
    public let style: CloudTreeStyle

    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    public var body: some View {
        HStack(alignment: .center, spacing: GlobalFontMagnification.scaledSize(style.iconGap, percent: magnification)) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: style.iconSize, weight: .medium))
                    .foregroundStyle(iconTint)
                    .frame(width: style.iconSlot, height: style.iconSize)
            }
            HStack(alignment: .firstTextBaseline, spacing: style.rowGrid.detailGap) {
                Text(style.groupLabelStyle == .uppercased ? title.uppercased() : title)
                    .tracking(style.groupLabelStyle == .uppercased ? 0.8 : 0)
                    .cmuxFont(size: style.groupLabelSize, weight: .medium, design: style.fontDesign)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if style.showsGroupCounts, let count {
                    Text(count.text)
                        .cmuxFont(size: style.detailSize, design: style.fontDesign, monospacedDigit: true)
                        .foregroundStyle(count.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        // The title truncates first; a clipped "1/5…" would misstate usage.
                        .fixedSize()
                        .accessibilityLabel(count.accessibilityLabel ?? count.text)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, style.rowGrid.trailingPadding)
    }
}

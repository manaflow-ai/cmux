import SwiftUI

struct RightSidebarChromeBarModifier: ViewModifier {
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    var leadingPadding: CGFloat
    var trailingPadding: CGFloat
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, UIScaleSettings.scaled(leadingPadding, by: uiScaleFactor))
            .padding(.trailing, UIScaleSettings.scaled(trailingPadding, by: uiScaleFactor))
            .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding(uiScaleFactor: uiScaleFactor))
            .frame(height: RightSidebarChromeMetrics.scaledBarHeight(height, uiScaleFactor: uiScaleFactor))
    }
}

struct RightSidebarChromePillModifier: ViewModifier {
    @Environment(\.uiScaleFactor) private var uiScaleFactor

    var isSelected: Bool
    var isHovered: Bool
    var selectedForeground: Color = .primary
    var defaultForeground: Color = .secondary
    var horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding
    var geometryKeyPrefix: String?

    func body(content: Content) -> some View {
        content
            .foregroundColor(isSelected ? selectedForeground : defaultForeground)
            .padding(.horizontal, RightSidebarChromeMetrics.controlHorizontalPadding(horizontalPadding, uiScaleFactor: uiScaleFactor))
            .frame(height: RightSidebarChromeMetrics.controlHeight(uiScaleFactor: uiScaleFactor))
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: geometryKeyPrefix,
                isVisible: true
            )
            .background(
                RoundedRectangle(
                    cornerRadius: RightSidebarChromeMetrics.controlCornerRadius(uiScaleFactor: uiScaleFactor),
                    style: .continuous
                )
                    .fill(backgroundColor)
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: RightSidebarChromeMetrics.controlCornerRadius(uiScaleFactor: uiScaleFactor),
                    style: .continuous
                )
            )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }
}

struct RightSidebarChromeBottomBorderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            WindowChromeBorder(orientation: .horizontal, ignoresSafeArea: false)
        }
    }
}

extension View {
    func rightSidebarChromeBar(
        leadingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        trailingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        height: CGFloat = RightSidebarChromeMetrics.secondaryBarHeight
    ) -> some View {
        modifier(
            RightSidebarChromeBarModifier(
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding,
                height: height
            )
        )
    }

    func rightSidebarChromePill(
        isSelected: Bool,
        isHovered: Bool,
        selectedForeground: Color = .primary,
        defaultForeground: Color = .secondary,
        horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding,
        geometryKeyPrefix: String? = nil
    ) -> some View {
        modifier(
            RightSidebarChromePillModifier(
                isSelected: isSelected,
                isHovered: isHovered,
                selectedForeground: selectedForeground,
                defaultForeground: defaultForeground,
                horizontalPadding: horizontalPadding,
                geometryKeyPrefix: geometryKeyPrefix
            )
        )
    }

    func rightSidebarChromeBottomBorder() -> some View {
        modifier(RightSidebarChromeBottomBorderModifier())
    }
}

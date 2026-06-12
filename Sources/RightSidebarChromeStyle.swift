import SwiftUI

enum HeaderChromeIconStyle {
    static let opacity = 0.86
    static let hoveredOpacity = 0.96
    static let pressedOpacity = 1.0
    static let disabledOpacity = 0.34
    static let weight: Font.Weight = .regular
    static let foregroundColor = Color(nsColor: .secondaryLabelColor)
    static let sidebarGlyphStrokeWidth: CGFloat = 1

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .cmuxSymbolRasterSize(RightSidebarChromeMetrics.headerIconSize, weight: weight)
    }

    static func foregroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed {
            return pressedOpacity
        }
        if isHovering {
            return hoveredOpacity
        }
        return opacity
    }

    static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed {
            return 0.14
        }
        if isHovering {
            return hoverBackground ? 0.09 : 0.07
        }
        return 0
    }

    static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed {
            return 0.11
        }
        if isHovering {
            return 0.07
        }
        return buttonBackground ? 0.05 : 0
    }
}

enum RightSidebarChromeControlStyle {
    static let modeIconSize: CGFloat = 11
    static let secondaryIconSize: CGFloat = 10
    static let labelSize: CGFloat = 11
    static let iconWeight = HeaderChromeIconStyle.weight
    static let labelWeight = HeaderChromeIconStyle.weight
    static let foregroundColor = HeaderChromeIconStyle.foregroundColor

    static func foregroundOpacity(isSelected: Bool, isHovered: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return HeaderChromeIconStyle.disabledOpacity }
        if isSelected {
            return HeaderChromeIconStyle.pressedOpacity
        }
        return HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovered,
            isPressed: false,
            isEnabled: isEnabled
        )
    }
}

struct RightSidebarChromeBarModifier: ViewModifier {
    var leadingPadding: CGFloat
    var trailingPadding: CGFloat
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
            .frame(height: height)
    }
}

struct RightSidebarChromePillModifier: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    var horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding
    var geometryKeyPrefix: String?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                RightSidebarChromeControlStyle.foregroundColor.opacity(foregroundOpacity)
            )
            .padding(.horizontal, horizontalPadding)
            .frame(height: RightSidebarChromeMetrics.controlHeight)
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: geometryKeyPrefix,
                isVisible: true
            )
            .background(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.controlCornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.controlCornerRadius, style: .continuous)
            )
    }

    private var foregroundOpacity: Double {
        RightSidebarChromeControlStyle.foregroundOpacity(
            isSelected: isSelected,
            isHovered: isHovered
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

struct RightSidebarHeaderIconButtonStyle: ButtonStyle {
    var iconGeometryKeyPrefix: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        RightSidebarHeaderIconButtonStyleBody(
            configuration: configuration,
            iconGeometryKeyPrefix: iconGeometryKeyPrefix
        )
    }
}

private struct RightSidebarHeaderIconButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let iconGeometryKeyPrefix: String?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .symbolRenderingMode(.monochrome)
            .frame(
                width: RightSidebarChromeMetrics.headerIconFrameSize,
                height: RightSidebarChromeMetrics.headerIconFrameSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: iconGeometryKeyPrefix,
                isVisible: true
            )
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .foregroundStyle(HeaderChromeIconStyle.foregroundColor.opacity(foregroundOpacity))
            .background {
                if backgroundOpacity > 0 {
                    RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(backgroundOpacity))
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }

    private var foregroundOpacity: Double {
        HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var backgroundOpacity: Double {
        HeaderChromeIconStyle.backgroundOpacity(
            hoverBackground: false,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
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
        horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding,
        geometryKeyPrefix: String? = nil
    ) -> some View {
        modifier(
            RightSidebarChromePillModifier(
                isSelected: isSelected,
                isHovered: isHovered,
                horizontalPadding: horizontalPadding,
                geometryKeyPrefix: geometryKeyPrefix
            )
        )
    }

    func rightSidebarChromeBottomBorder() -> some View {
        modifier(RightSidebarChromeBottomBorderModifier())
    }

    func rightSidebarHeaderControlAlignment() -> some View {
        alignmentGuide(VerticalAlignment.center) { dimensions in
            dimensions[VerticalAlignment.center] + RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment
        }
    }
}

/// Every stable customization token accepted by Dynamic Notch notifications.
public enum DynamicNotchAppearanceToken: String, CaseIterable, Sendable, Hashable {
    case compactWidth
    case compactHeight
    case syntheticNotchWidth
    case expandedWidth
    case maximumExpandedHeight
    case shellPadding
    case scrollContainerHorizontalPadding
    case floatingOuterPadding
    case compactHorizontalPadding
    case compactVerticalPadding
    case rowHorizontalPadding
    case rowTopPadding
    case rowBottomPadding
    case dividerHorizontalPadding
    case floatingCornerRadius
    case notchTopCornerRadius
    case notchBottomCornerRadius
    case rowCornerRadius
    case compactCornerRadius
    case inputCornerRadius
    case inputHorizontalPadding
    case inputVerticalPadding
    case compactIconSize
    case notificationIconSize
    case notificationIconFrame
    case shellBorderWidth
    case inputBorderWidth
    case shadowRadius
    case hoverShadowRadius

    case compactSpacing
    case rowSpacing
    case headerSpacing
    case textSpacing
    case inputSpacing
    case inputLabelSpacing
    case actionSpacing

    case shellBackgroundColor
    case shellBorderColor
    case shadowColor
    case primaryTextColor
    case secondaryTextColor
    case accentColor
    case dividerColor
    case rowBackgroundColor
    case compactBackgroundColor
    case compactTextColor
    case compactIconColor
    case closeButtonColor
    case inputBackgroundColor
    case inputTextColor
    case inputBorderColor

    case animationDuration
    case arrivalRevealDuration
    case shellBackgroundOpacity
    case shadowOpacity
    case hoverShadowOpacity
    case rowBackgroundOpacity
    case compactBackgroundOpacity
    case inputBackgroundOpacity
    case titleLineLimit
    case subtitleLineLimit
    case bodyLineLimit
    case showScrollIndicators
    case pointerRevealDistance
    case retractWhenPointerLeaves

    /// The editor group for this token.
    public var group: DynamicNotchAppearanceGroup {
        switch self {
        case .compactSpacing,
             .rowSpacing,
             .headerSpacing,
             .textSpacing,
             .inputSpacing,
             .inputLabelSpacing,
             .actionSpacing:
            .spacing
        case .shellBackgroundColor,
             .shellBorderColor,
             .shadowColor,
             .primaryTextColor,
             .secondaryTextColor,
             .accentColor,
             .dividerColor,
             .rowBackgroundColor,
             .compactBackgroundColor,
             .compactTextColor,
             .compactIconColor,
             .closeButtonColor,
             .inputBackgroundColor,
             .inputTextColor,
             .inputBorderColor:
            .colors
        case .animationDuration,
             .arrivalRevealDuration,
             .shellBackgroundOpacity,
             .shadowOpacity,
             .hoverShadowOpacity,
             .shadowRadius,
             .hoverShadowRadius,
             .rowBackgroundOpacity,
             .compactBackgroundOpacity,
             .inputBackgroundOpacity,
             .titleLineLimit,
             .subtitleLineLimit,
             .bodyLineLimit,
             .showScrollIndicators,
             .pointerRevealDistance,
             .retractWhenPointerLeaves:
            .behavior
        default:
            .layout
        }
    }

    /// The accepted type and validation range for this token.
    public var valueKind: DynamicNotchAppearanceValueKind {
        switch self {
        case .compactWidth:
            .number(minimum: 72, maximum: 360, step: 1)
        case .compactHeight:
            .number(minimum: 24, maximum: 120, step: 1)
        case .syntheticNotchWidth:
            .number(minimum: 72, maximum: 480, step: 1)
        case .expandedWidth:
            .number(minimum: 300, maximum: 1_200, step: 1)
        case .maximumExpandedHeight:
            .number(minimum: 160, maximum: 1_400, step: 1)
        case .shellPadding,
             .scrollContainerHorizontalPadding,
             .compactHorizontalPadding,
             .rowHorizontalPadding,
             .rowTopPadding,
             .rowBottomPadding,
             .dividerHorizontalPadding,
             .inputHorizontalPadding:
            .number(minimum: 0, maximum: 64, step: 1)
        case .floatingOuterPadding:
            .number(minimum: 0, maximum: 80, step: 1)
        case .compactVerticalPadding:
            .number(minimum: 0, maximum: 32, step: 1)
        case .inputVerticalPadding:
            .number(minimum: 0, maximum: 24, step: 1)
        case .floatingCornerRadius,
             .notchTopCornerRadius,
             .notchBottomCornerRadius,
             .rowCornerRadius,
             .compactCornerRadius,
             .inputCornerRadius:
            .number(minimum: 0, maximum: 64, step: 1)
        case .compactIconSize:
            .number(minimum: 8, maximum: 48, step: 1)
        case .notificationIconSize:
            .number(minimum: 8, maximum: 64, step: 1)
        case .notificationIconFrame:
            .number(minimum: 8, maximum: 96, step: 1)
        case .shellBorderWidth,
             .inputBorderWidth:
            .number(minimum: 0, maximum: 8, step: 0.5)
        case .shadowRadius,
             .hoverShadowRadius:
            .number(minimum: 0, maximum: 64, step: 1)
        case .compactSpacing,
             .inputSpacing,
             .actionSpacing:
            .number(minimum: 0, maximum: 32, step: 1)
        case .rowSpacing,
             .headerSpacing:
            .number(minimum: 0, maximum: 48, step: 1)
        case .textSpacing,
             .inputLabelSpacing:
            .number(minimum: 0, maximum: 24, step: 1)
        case .animationDuration:
            .number(minimum: 0, maximum: 2, step: 0.05)
        case .arrivalRevealDuration:
            .number(minimum: 0, maximum: 30, step: 0.25)
        case .pointerRevealDistance:
            .number(minimum: 0, maximum: 400, step: 1)
        case .shellBackgroundOpacity,
             .shadowOpacity,
             .hoverShadowOpacity,
             .rowBackgroundOpacity,
             .compactBackgroundOpacity,
             .inputBackgroundOpacity:
            .number(minimum: 0, maximum: 1, step: 0.05)
        case .titleLineLimit,
             .subtitleLineLimit:
            .integer(minimum: 1, maximum: 12)
        case .bodyLineLimit:
            .integer(minimum: 1, maximum: 40)
        case .showScrollIndicators,
             .retractWhenPointerLeaves:
            .boolean
        case .shellBackgroundColor,
             .shellBorderColor,
             .shadowColor,
             .primaryTextColor,
             .secondaryTextColor,
             .accentColor,
             .dividerColor,
             .rowBackgroundColor,
             .compactBackgroundColor,
             .compactTextColor,
             .compactIconColor,
             .closeButtonColor,
             .inputBackgroundColor,
             .inputTextColor,
             .inputBorderColor:
            .color
        }
    }

    /// The built-in value that preserves the original cmux presentation.
    public var defaultValue: DynamicNotchAppearanceValue {
        switch self {
        case .compactWidth:
            .number(84)
        case .compactHeight:
            .number(26)
        case .syntheticNotchWidth:
            .number(164)
        case .expandedWidth:
            .number(460)
        case .maximumExpandedHeight:
            .number(520)
        case .shellPadding:
            .number(15)
        case .scrollContainerHorizontalPadding:
            .number(0)
        case .floatingOuterPadding:
            .number(20)
        case .compactHorizontalPadding:
            .number(8)
        case .compactVerticalPadding:
            .number(4)
        case .rowHorizontalPadding:
            .number(18)
        case .rowTopPadding:
            .number(16)
        case .rowBottomPadding:
            .number(18)
        case .dividerHorizontalPadding:
            .number(18)
        case .floatingCornerRadius:
            .number(20)
        case .notchTopCornerRadius:
            .number(15)
        case .notchBottomCornerRadius:
            .number(20)
        case .rowCornerRadius,
             .compactCornerRadius:
            .number(0)
        case .inputCornerRadius:
            .number(6)
        case .inputHorizontalPadding:
            .number(7)
        case .inputVerticalPadding:
            .number(5)
        case .compactIconSize:
            .number(13)
        case .notificationIconSize:
            .number(24)
        case .notificationIconFrame:
            .number(30)
        case .shellBorderWidth:
            .number(1)
        case .inputBorderWidth:
            .number(1)
        case .shadowRadius:
            .number(10)
        case .hoverShadowRadius:
            .number(20)
        case .compactSpacing:
            .number(5)
        case .rowSpacing,
             .headerSpacing:
            .number(12)
        case .textSpacing:
            .number(3)
        case .inputSpacing,
             .actionSpacing:
            .number(8)
        case .inputLabelSpacing:
            .number(4)
        case .animationDuration:
            .number(0.28)
        case .arrivalRevealDuration:
            .number(3)
        case .pointerRevealDistance:
            .number(0)
        case .shadowOpacity,
             .hoverShadowOpacity:
            .number(0)
        case .shellBackgroundOpacity,
             .rowBackgroundOpacity,
             .compactBackgroundOpacity,
             .inputBackgroundOpacity:
            .number(1)
        case .titleLineLimit:
            .integer(2)
        case .subtitleLineLimit:
            .integer(1)
        case .bodyLineLimit:
            .integer(4)
        case .showScrollIndicators:
            .boolean(true)
        case .retractWhenPointerLeaves:
            .boolean(true)
        case .shellBackgroundColor,
             .shellBorderColor,
             .shadowColor,
             .primaryTextColor,
             .secondaryTextColor,
             .accentColor,
             .dividerColor,
             .rowBackgroundColor,
             .compactBackgroundColor,
             .compactTextColor,
             .compactIconColor,
             .closeButtonColor,
             .inputBackgroundColor,
             .inputTextColor,
             .inputBorderColor:
            .color(.system)
        }
    }

    /// Returns whether `value` matches this token's type and bounds.
    ///
    /// - Parameter value: The candidate value.
    public func accepts(_ value: DynamicNotchAppearanceValue) -> Bool {
        switch (valueKind, value) {
        case let (.number(minimum, maximum, _), .number(number)):
            number.isFinite && (minimum...maximum).contains(number)
        case let (.integer(minimum, maximum), .integer(integer)):
            (minimum...maximum).contains(integer)
        case (.boolean, .boolean):
            true
        case (.color, .color):
            true
        default:
            false
        }
    }
}

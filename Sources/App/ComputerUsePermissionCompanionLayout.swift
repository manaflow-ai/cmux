import Foundation

/// Geometry for the fixed-size permission companion beside System Settings.
///
/// The two rows intentionally share one leading column and one eight-point
/// gutter. Keeping these aliases tied to the onboarding token set prevents the
/// window controller and the view from drifting apart as the visual system is
/// tuned.
struct ComputerUsePermissionCompanionLayout {
    private static let tokens = ComputerUseOnboardingVisualTokens.reference

    static let size = tokens.companionSize
    static let horizontalInset = tokens.companionHorizontalInset
    static let verticalInset = tokens.companionVerticalInset
    static let leadingColumnWidth = tokens.companionLeadingColumnWidth
    static let headerHeight = tokens.companionHeaderHeight
    static let dragRowHeight = tokens.companionDragRowHeight
    static let columnSpacing = tokens.companionColumnSpacing
    static let rowSpacing = tokens.companionRowSpacing
    static let headerArrowSize = tokens.companionHeaderArrowSize
    static let dragContentSpacing = tokens.companionDragContentSpacing
    static let dragHorizontalInset = tokens.companionDragHorizontalInset
    static let helperIconSize = tokens.companionHelperIconSize
    static let rowCornerRadius = tokens.tileCornerRadius(for: dragRowHeight)
    static let helperIconCornerRadius = tokens.tileCornerRadius(for: helperIconSize)
    static let containerCornerRadius = tokens.companionCornerRadius
}

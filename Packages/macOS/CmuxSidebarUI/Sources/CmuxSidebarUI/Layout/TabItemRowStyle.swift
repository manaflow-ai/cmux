public import SwiftUI

/// Fully-resolved appearance for one workspace row, computed app-side from the
/// row settings, the current `ColorScheme`, the active flag, and the workspace
/// snapshot's custom color, then handed to ``TabItemView``.
///
/// All color math lives in the app target's `SidebarAppearanceSupport` (it reads
/// `WorkspaceTabColorSettings` and the selection-color overrides). Resolving it
/// into this value type keeps ``TabItemView`` free of those app-target helpers
/// while honoring the snapshot-boundary rule: the row renders pure values and
/// closures, never a live store.
public struct TabItemRowStyle {
    /// `activeSecondaryColor(opacity)` from the legacy view: secondary text/icon
    /// color at a caller-chosen opacity, inverted when the row is active.
    public let activeSecondaryColor: (Double) -> Color
    public let primaryTextColor: Color
    public let unreadBadgeFillColor: Color
    public let unreadBadgeTextColor: Color
    public let progressTrackColor: Color
    public let progressFillColor: Color
    public let pullRequestForegroundColor: Color
    public let backgroundColor: Color
    public let borderColor: Color
    public let borderLineWidth: CGFloat
    public let showsLeadingRail: Bool
    public let railColor: Color
    public let usesInvertedActiveForeground: Bool
    public let shortcutHintEmphasis: Double
    public let titleFontWeight: Font.Weight
    public let fontScale: CGFloat
    /// The app's `cmuxAccentColor()` for the row's top drop indicator; injected
    /// because that helper lives in the app target.
    public let accentColor: Color

    public init(
        activeSecondaryColor: @escaping (Double) -> Color,
        primaryTextColor: Color,
        unreadBadgeFillColor: Color,
        unreadBadgeTextColor: Color,
        progressTrackColor: Color,
        progressFillColor: Color,
        pullRequestForegroundColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        borderLineWidth: CGFloat,
        showsLeadingRail: Bool,
        railColor: Color,
        usesInvertedActiveForeground: Bool,
        shortcutHintEmphasis: Double,
        titleFontWeight: Font.Weight,
        fontScale: CGFloat,
        accentColor: Color
    ) {
        self.activeSecondaryColor = activeSecondaryColor
        self.primaryTextColor = primaryTextColor
        self.unreadBadgeFillColor = unreadBadgeFillColor
        self.unreadBadgeTextColor = unreadBadgeTextColor
        self.progressTrackColor = progressTrackColor
        self.progressFillColor = progressFillColor
        self.pullRequestForegroundColor = pullRequestForegroundColor
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.borderLineWidth = borderLineWidth
        self.showsLeadingRail = showsLeadingRail
        self.railColor = railColor
        self.usesInvertedActiveForeground = usesInvertedActiveForeground
        self.shortcutHintEmphasis = shortcutHintEmphasis
        self.titleFontWeight = titleFontWeight
        self.fontScale = fontScale
        self.accentColor = accentColor
    }
}

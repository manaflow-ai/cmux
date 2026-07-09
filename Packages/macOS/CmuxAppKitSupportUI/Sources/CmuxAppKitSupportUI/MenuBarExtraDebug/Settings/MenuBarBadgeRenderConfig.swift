#if canImport(AppKit)

public import Foundation

/// Resolved geometry and type metrics for drawing the unread-count badge on the
/// menu-bar icon.
///
/// The app target's menu-bar icon renderer consumes this value to position the
/// badge rect and lay out the digit glyphs. ``MenuBarIconDebugSettings`` produces
/// it from the live `@AppStorage`-backed debug tuning keys, so the Menu Bar Extra
/// Debug panel and the production renderer share one source of truth.
public struct MenuBarBadgeRenderConfig: Equatable, Sendable {
    /// The badge rectangle, in the menu-bar icon's drawing coordinate space.
    public var badgeRect: NSRect
    /// Font size used when the badge text is a single digit.
    public var singleDigitFontSize: CGFloat
    /// Font size used when the badge text is two or more digits.
    public var multiDigitFontSize: CGFloat
    /// Vertical offset applied to single-digit badge text.
    public var singleDigitYOffset: CGFloat
    /// Vertical offset applied to multi-digit badge text.
    public var multiDigitYOffset: CGFloat
    /// Horizontal adjustment applied to single-digit badge text.
    public var singleDigitXAdjust: CGFloat
    /// Horizontal adjustment applied to multi-digit badge text.
    public var multiDigitXAdjust: CGFloat
    /// Width adjustment applied to the badge text rect.
    public var textRectWidthAdjust: CGFloat

    /// Creates a render config.
    public init(
        badgeRect: NSRect,
        singleDigitFontSize: CGFloat,
        multiDigitFontSize: CGFloat,
        singleDigitYOffset: CGFloat,
        multiDigitYOffset: CGFloat,
        singleDigitXAdjust: CGFloat,
        multiDigitXAdjust: CGFloat,
        textRectWidthAdjust: CGFloat
    ) {
        self.badgeRect = badgeRect
        self.singleDigitFontSize = singleDigitFontSize
        self.multiDigitFontSize = multiDigitFontSize
        self.singleDigitYOffset = singleDigitYOffset
        self.multiDigitYOffset = multiDigitYOffset
        self.singleDigitXAdjust = singleDigitXAdjust
        self.multiDigitXAdjust = multiDigitXAdjust
        self.textRectWidthAdjust = textRectWidthAdjust
    }
}

#endif

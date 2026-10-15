import CoreGraphics

/// Sizes for the Chromium crash page and the "Page unresponsive" card
/// (design spec §8). Each is a base size times ``BrowserChromeMetrics/scale``.
extension BrowserChromeMetrics {
    /// Warning symbol on the crash page. Base `28`.
    var pageFailureSymbolSize: CGFloat { 28 * scale }

    /// Crash page title ("Aw, Snap!"). Base `17`.
    var pageFailureTitleFontSize: CGFloat { 17 * scale }

    /// Crash page and hang card body text. Base `13`.
    var pageFailureBodyFontSize: CGFloat { 13 * scale }

    /// "Error code: …" line on the crash page. Base `11`.
    var pageFailureCodeFontSize: CGFloat { 11 * scale }

    /// Widest the crash page text column grows. Base `420`.
    var pageFailureMaxWidth: CGFloat { 420 * scale }

    /// How far above center the crash page sits: one toolbar row (26-point
    /// buttons plus 4-point padding above and below). Base `34`.
    var pageFailureLift: CGFloat { 34 * scale }

    /// Spacing between the crash page's lines. Base `10`.
    var pageFailureSpacing: CGFloat { 10 * scale }

    /// Corner radius of the "Page unresponsive" card, matching the omnibar
    /// pill and prompt bars. Base `10`.
    var pageFailureCardCornerRadius: CGFloat { 10 * scale }

    /// Inner padding of the "Page unresponsive" card. Base `10`.
    var pageFailureCardPadding: CGFloat { 10 * scale }

    /// Width bounds of the "Page unresponsive" card. Base `320`–`480`.
    var pageFailureCardMinWidth: CGFloat { 320 * scale }
    var pageFailureCardMaxWidth: CGFloat { 480 * scale }
}

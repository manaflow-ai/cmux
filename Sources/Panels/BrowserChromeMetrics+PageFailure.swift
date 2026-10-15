import CoreGraphics

/// Sizes for the Chromium "Page unresponsive" card (design spec §8: same
/// material and radius as the §4 prompt bar). The crash page uses the shared
/// full-page `recovery*` sizes. Each is a base size times
/// ``BrowserChromeMetrics/scale``.
extension BrowserChromeMetrics {
    /// Corner radius of the card, matching the omnibar pill. Base `10`.
    var unresponsiveCardCornerRadius: CGFloat { 10 * scale }

    /// Inner padding of the card. Base `10`.
    var unresponsiveCardPadding: CGFloat { 10 * scale }

    /// Narrowest the card gets. Base `320`.
    var unresponsiveCardMinWidth: CGFloat { 320 * scale }

    /// Widest the card gets. Base `480`.
    var unresponsiveCardMaxWidth: CGFloat { 480 * scale }
}

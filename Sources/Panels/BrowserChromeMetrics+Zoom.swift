import CoreGraphics

/// Sizes of the zoom chip in the browser toolbar and its popover (design spec §7).
extension BrowserChromeMetrics {
    /// Point size of the zoom chip's percentage. Base `11`.
    var zoomChipFontSize: CGFloat { accessoryIconFontSize }

    /// Horizontal padding inside the zoom chip. Base `6`.
    var zoomChipHorizontalPadding: CGFloat { buttonIconSize * (6.0 / 22.0) }

    /// Vertical padding inside the zoom chip. Base `2`.
    var zoomChipVerticalPadding: CGFloat { buttonIconSize * (2.0 / 22.0) }

    /// Height of the zoom chip (an accessory button's edge). Base `22`.
    var zoomChipHeight: CGFloat { buttonIconSize }

    /// Point size of the zoom popover's text and glyphs. Base `12`.
    var zoomPopoverFontSize: CGFloat { omnibarFontSize }

    /// Square edge of the zoom popover's − and + buttons. Base `22`.
    var zoomPopoverButtonSize: CGFloat { buttonIconSize }

    /// Padding inside the zoom popover. Base `8`.
    var zoomPopoverPadding: CGFloat { buttonIconSize * (8.0 / 22.0) }
}

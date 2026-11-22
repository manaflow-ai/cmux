import CmuxNextBrowser
import CoreGraphics

/// Where a popup panel goes and how large it is (pure). The page's size is
/// the content size (the panel adds its title bar), clamped between a
/// minimum and the opener screen's visible frame. A position the page gave
/// is used when the whole panel fits on that screen there; otherwise the
/// panel centers over the opener's window, inside the screen.
nonisolated enum BrowserPopupPanelGeometry {
    /// Content size when the page gave none (an extension's popup window).
    static let defaultContent = CGSize(width: 500, height: 600)
    /// The smallest content a page can ask for.
    static let minimumContent = CGSize(width: 240, height: 160)
    /// Space kept free around a panel that fills the screen.
    static let screenMargin: CGFloat = 8

    /// The panel frame (AppKit screen coordinates, bottom-left origin).
    /// `primaryHeight` is the primary display's height: page positions are
    /// measured from its top-left.
    static func frame(for request: BrowserPopupRequest, opener: CGRect, visibleFrame: CGRect,
                      primaryHeight: CGFloat, titleHeight: CGFloat) -> CGRect {
        let maxContent = CGSize(
            width: max(visibleFrame.width - 2 * screenMargin, minimumContent.width),
            height: max(visibleFrame.height - 2 * screenMargin - titleHeight, minimumContent.height)
        )
        let content = CGSize(
            width: dimension(request.size.width, fallback: defaultContent.width, minimum: minimumContent.width, maximum: maxContent.width),
            height: dimension(request.size.height, fallback: defaultContent.height, minimum: minimumContent.height, maximum: maxContent.height)
        )
        let size = CGSize(width: content.width, height: content.height + titleHeight)
        if let origin = request.origin {
            let placed = CGRect(x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height)
            if visibleFrame.contains(placed) { return placed }
        }
        var frame = CGRect(x: opener.midX - size.width / 2, y: opener.midY - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return frame
    }

    private static func dimension(_ asked: CGFloat, fallback: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(asked > 0 ? asked : fallback, minimum), maximum)
    }
}

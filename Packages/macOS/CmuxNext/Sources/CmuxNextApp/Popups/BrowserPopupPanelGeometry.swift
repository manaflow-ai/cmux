import CmuxNextBrowser
import CoreGraphics

/// Where a popup panel goes and how large it is (pure).
nonisolated enum BrowserPopupPanelGeometry {
    /// Content size when the page gave none (an extension's popup window).
    static let defaultContent = CGSize(width: 500, height: 600)
    /// The smallest content a page can ask for.
    static let minimumContent = CGSize(width: 240, height: 160)

    /// The panel frame (AppKit screen coordinates, bottom-left origin).
    static func frame(for request: BrowserPopupRequest, opener: CGRect, visibleFrame: CGRect,
                      primaryHeight: CGFloat, titleHeight: CGFloat) -> CGRect {
        .zero
    }
}

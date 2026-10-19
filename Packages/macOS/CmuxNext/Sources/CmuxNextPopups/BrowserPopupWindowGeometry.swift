public import CmuxNextBrowser
public import CoreGraphics

/// Where a popup window goes and how large it is (pure), following Chrome:
///
/// - The page's width and height are the page (content) size: Blink's
///   `create_window.cc` reads `width`/`height` as the inner size and raises
///   a given value below `kMinimumWindowSize` (100) to it. The window adds
///   the title bar and the location bar (`BrowserView::GetSavedWindowPlacement`
///   adds the toolbar height, then the frame).
/// - A size the page did not give is the opener window's
///   (`WindowSizer::DetermineWindowBoundsAndShowState` takes the last active
///   window's bounds when the requested bounds are empty).
/// - `left`/`top` place the window's top-left corner. Without them the
///   window opens 22 pt right of and below the opener's top-left corner
///   (`WindowSizer::GetDefaultPopupOrigin`, `kWindowTilePixels`).
/// - The result is moved, then shrunk, to fit the screen's visible frame
///   (`gfx::Rect::AdjustToFit(display.work_area())`), with no margin.
public nonisolated enum BrowserPopupWindowGeometry {
    /// Blink's `kMinimumWindowSize`: the smallest page width or height a
    /// page can ask for.
    public static let minimumContent: CGFloat = 100
    /// Chrome's `kWindowTilePixels`: how far a popup without a position
    /// opens from its opener's top-left corner.
    public static let cascadeOffset: CGFloat = 22

    /// The window frame (AppKit screen coordinates, bottom-left origin).
    ///
    /// - Parameters:
    ///   - opener: the frame of the window the popup opens from.
    ///   - fallbackContent: the page size used for a dimension the page did
    ///     not give (the opener's size when opening, the current page size
    ///     when resizing).
    ///   - primaryHeight: the primary display's height; page positions are
    ///     measured from its top-left corner.
    ///   - chromeHeight: the title bar plus the location bar.
    public static func frame(for request: BrowserPopupRequest, opener: CGRect, fallbackContent: CGSize, visibleFrame: CGRect,
                      primaryHeight: CGFloat, chromeHeight: CGFloat) -> CGRect {
        let content = CGSize(width: dimension(request.size.width, fallback: fallbackContent.width),
                             height: dimension(request.size.height, fallback: fallbackContent.height))
        let size = CGSize(width: content.width, height: content.height + chromeHeight)
        let top: CGPoint = request.origin.map { CGPoint(x: $0.x, y: primaryHeight - $0.y) }
            ?? CGPoint(x: opener.minX + cascadeOffset, y: opener.maxY - cascadeOffset)
        let frame = CGRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        return fit(frame, in: visibleFrame)
    }

    /// `request` without a position Chromium made up. With no position from
    /// the page, Chromium fills in `WindowSizer::GetDefaultPopupOrigin`,
    /// which is the work area's top-left corner when no Chrome browser
    /// window is active, and in cmux none ever is. That corner is dropped
    /// so the window cascades from its opener as Chrome's does; a page that
    /// asks for exactly that corner opens 22 pt off it.
    public static func droppingChromiumDefaultOrigin(_ request: BrowserPopupRequest, visibleFrame: CGRect,
                                              primaryHeight: CGFloat) -> BrowserPopupRequest {
        guard let origin = request.origin else { return request }
        let corner = CGPoint(x: visibleFrame.minX, y: primaryHeight - visibleFrame.maxY)
        guard abs(origin.x - corner.x) < 0.5, abs(origin.y - corner.y) < 0.5 else { return request }
        var request = request
        request.origin = nil
        return request
    }

    /// The page asked for `asked` (0 = not given): at least
    /// `minimumContent`, else `fallback`.
    private static func dimension(_ asked: CGFloat, fallback: CGFloat) -> CGFloat {
        asked > 0 ? max(asked, minimumContent) : max(fallback, minimumContent)
    }

    /// `gfx::Rect::AdjustToFit`: shrinks `frame` to the area's size, then
    /// moves it inside. An empty area (no screen) leaves it as is.
    public static func fit(_ frame: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return frame }
        var fitted = frame
        fitted.size.width = min(frame.width, area.width)
        fitted.size.height = min(frame.height, area.height)
        fitted.origin.x = min(max(frame.minX, area.minX), area.maxX - fitted.width)
        // Keep the top (title bar) where it was asked when the height shrinks.
        let top = min(max(frame.maxY, area.minY + fitted.height), area.maxY)
        fitted.origin.y = top - fitted.height
        return fitted
    }
}

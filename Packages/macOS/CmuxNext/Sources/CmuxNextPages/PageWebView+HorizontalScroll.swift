public import AppKit
public import CmuxNextDesign

/// A page keeps a horizontal scroll over its own sideways scrollers (MARKDOWN-TABLE-SCROLL, user
/// 2026-10-20): a wide Markdown table, a long code line, a diff. The page's script reports the
/// pointer over one (``PageInputReadiness/isPointerOverSidewaysScroller``); elsewhere the layout's
/// column strip still takes the swipe.
extension PageWebView: HorizontalScrollClaiming {
    public func claimsHorizontalScroll(at point: NSPoint) -> Bool {
        bounds.contains(point) && inputReadiness.isPointerOverSidewaysScroller
    }
}

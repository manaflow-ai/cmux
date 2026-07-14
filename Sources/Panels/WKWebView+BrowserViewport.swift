import AppKit
import CmuxBrowser
import WebKit

extension WKWebView {
    var cmuxBrowserViewportLayoutMode: BrowserViewportLayout.Mode {
        (self as? CmuxWebView)?.browserViewportModel?.viewport == nil ? .native : .emulated
    }

    var cmuxBrowserViewportAutoresizingMask: NSView.AutoresizingMask {
        cmuxBrowserViewportLayoutMode == .native ? [.width, .height] : []
    }

    func cmuxBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout {
        BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: (self as? CmuxWebView)?.browserViewportModel?.viewport
        )
    }

    func cmuxBrowserViewportLayoutMatches(_ containerBounds: CGRect, epsilon: Double = 0.5) -> Bool {
        let layout = cmuxBrowserViewportLayout(in: containerBounds)
        return Self.cmuxBrowserViewportRect(frame, matches: layout.frame, epsilon: epsilon) &&
            Self.cmuxBrowserViewportRect(bounds, matches: layout.bounds, epsilon: epsilon) &&
            autoresizingMask == cmuxBrowserViewportAutoresizingMask
    }

    @discardableResult
    func cmuxApplyBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout {
        let layout = cmuxBrowserViewportLayout(in: containerBounds)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = cmuxBrowserViewportAutoresizingMask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Self.cmuxBrowserViewportRect(frame, matches: layout.frame) {
            frame = layout.frame
        }
        if !Self.cmuxBrowserViewportRect(bounds, matches: layout.bounds) {
            bounds = layout.bounds
        }
        CATransaction.commit()
        return layout
    }

    private static func cmuxBrowserViewportRect(
        _ lhs: CGRect,
        matches rhs: CGRect,
        epsilon: Double = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= epsilon &&
            abs(lhs.minY - rhs.minY) <= epsilon &&
            abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }
}

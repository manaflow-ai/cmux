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
            viewport: (self as? CmuxWebView)?.browserViewportModel?.viewport,
            pageZoom: Double(pageZoom)
        )
    }

    func cmuxBrowserViewportLayoutMatches(_ containerBounds: CGRect, epsilon: Double = 0.5) -> Bool {
        let layout = cmuxBrowserViewportLayout(in: containerBounds)
        return Self.cmuxBrowserViewportRect(frame, matches: layout.frame, epsilon: epsilon) &&
            Self.cmuxBrowserViewportRect(bounds, matches: layout.webViewBounds, epsilon: epsilon) &&
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
        if !Self.cmuxBrowserViewportRect(bounds, matches: layout.webViewBounds) {
            bounds = layout.webViewBounds
        }
        CATransaction.commit()
        return layout
    }

    func cmuxRestoreBrowserViewportAfterTemporaryReparenting(
        to previousSuperview: NSView?,
        frame previousFrame: NSRect,
        bounds previousBounds: NSRect,
        autoresizingMask previousAutoresizingMask: NSView.AutoresizingMask,
        translatesAutoresizingMaskIntoConstraints previousTranslatesAutoresizingMaskIntoConstraints: Bool,
        anchor: NSView?,
        position: NSWindow.OrderingMode
    ) {
        removeFromSuperview()
        if let previousSuperview {
            if let anchor, anchor.superview === previousSuperview {
                previousSuperview.addSubview(self, positioned: position, relativeTo: anchor)
            } else {
                previousSuperview.addSubview(self)
            }
        }

        let hasVisibleWebKitCompanion = previousSuperview?
            .browserPortalHasVisibleWebKitCompanionSubview(for: self) ?? false
        if BrowserViewportLayout.shouldPreservePreviousGeometryOnRestore(
            hasPreviousHost: previousSuperview != nil,
            hasVisibleWebKitCompanion: hasVisibleWebKitCompanion
        ) {
            frame = previousFrame
            bounds = previousBounds
            autoresizingMask = previousAutoresizingMask
            translatesAutoresizingMaskIntoConstraints = previousTranslatesAutoresizingMaskIntoConstraints
        } else if let previousSuperview {
            cmuxApplyBrowserViewportLayout(in: previousSuperview.bounds)
        }
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

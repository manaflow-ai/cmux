import AppKit
import CmuxBrowser
import ObjectiveC.runtime
import WebKit

private final class BrowserViewportWeakHostBox: NSObject {
    weak var value: BrowserViewportHostView?
}

private enum BrowserViewportAssociatedKeys {
    static var host: UInt8 = 0
}

extension WKWebView {
    var cmuxBrowserViewportHostView: BrowserViewportHostView? {
        get {
            (objc_getAssociatedObject(self, &BrowserViewportAssociatedKeys.host)
                as? BrowserViewportWeakHostBox)?.value
        }
        set {
            if let box = objc_getAssociatedObject(
                self,
                &BrowserViewportAssociatedKeys.host
            ) as? BrowserViewportWeakHostBox {
                box.value = newValue
            } else {
                let box = BrowserViewportWeakHostBox()
                box.value = newValue
                objc_setAssociatedObject(
                    self,
                    &BrowserViewportAssociatedKeys.host,
                    box,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }
    }

    var cmuxBrowserViewportUsesHost: Bool {
        guard let host = cmuxBrowserViewportHostView else { return false }
        return superview === host
    }

    var cmuxBrowserViewportPresentationView: NSView {
        guard cmuxBrowserViewportUsesHost, let host = cmuxBrowserViewportHostView else {
            return self
        }
        return host
    }

    var cmuxBrowserViewportAttachmentSuperview: NSView? {
        cmuxBrowserViewportPresentationView.superview
    }

    var cmuxBrowserViewportAttachmentWindow: NSWindow? {
        cmuxBrowserViewportPresentationView.window ?? window
    }

    var cmuxBrowserViewportContainerBounds: CGRect? {
        cmuxBrowserViewportAttachmentSuperview?.bounds
    }

    var cmuxBrowserViewportLayoutMode: BrowserViewportLayout.Mode {
        (self as? CmuxWebView)?.browserViewportModel?.viewport == nil ? .native : .emulated
    }

    var cmuxBrowserViewportAutoresizingMask: NSView.AutoresizingMask {
        cmuxBrowserViewportLayoutMode == .native ? [.width, .height] : []
    }

    func cmuxBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: (self as? CmuxWebView)?.browserViewportModel?.viewport,
            pageZoom: Double(pageZoom)
        )
    }

    func cmuxBrowserViewportLayoutMatches(_ containerBounds: CGRect, epsilon: Double = 0.5) -> Bool {
        guard let layout = cmuxBrowserViewportLayout(in: containerBounds) else {
            return false
        }
        if cmuxBrowserViewportUsesHost, let host = cmuxBrowserViewportHostView {
            return host.matches(layout, epsilon: epsilon)
        }
        return Self.cmuxBrowserViewportRect(frame, matches: layout.frame, epsilon: epsilon) &&
            Self.cmuxBrowserViewportRect(bounds, matches: layout.webViewBounds, epsilon: epsilon) &&
            autoresizingMask == cmuxBrowserViewportAutoresizingMask
    }

    @discardableResult
    func cmuxApplyBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        guard let layout = cmuxBrowserViewportLayout(in: containerBounds) else {
            return nil
        }
        cmuxApplyBrowserViewportLayout(layout)
        return layout
    }

    func cmuxApplyBrowserViewportLayout(_ layout: BrowserViewportLayout) {
        if cmuxBrowserViewportUsesHost, let host = cmuxBrowserViewportHostView {
            host.apply(layout)
            return
        }
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
    }

    func cmuxApplyRawBrowserViewportGeometry(_ rawBounds: CGRect) {
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = cmuxBrowserViewportAutoresizingMask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Self.cmuxBrowserViewportRect(frame, matches: rawBounds) {
            frame = rawBounds
        }
        if !Self.cmuxBrowserViewportRect(bounds, matches: rawBounds) {
            bounds = rawBounds
        }
        CATransaction.commit()
    }

    @discardableResult
    func cmuxRestoreIntoBrowserViewportHostIfNeeded() -> Bool {
        cmuxBrowserViewportHostView?.restoreWebViewIfNeeded() ?? false
    }

    @discardableResult
    func cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe() -> Bool {
        cmuxBrowserViewportHostView?.restoreWebViewAfterExternalGeometryIfSafe() ?? false
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

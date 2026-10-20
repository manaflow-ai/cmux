public import AppKit
public import ObjectiveC.runtime
public import WebKit

private final class BrowserViewportWeakHostBox: NSObject {
    weak var value: BrowserViewportHostView?
}

private enum BrowserViewportAssociatedKeys {
    nonisolated(unsafe) static var host: UInt8 = 0
    nonisolated(unsafe) static var externalRenderHostDepth: UInt8 = 0
}

extension WKWebView {
    public var cmuxBrowserViewportHostView: BrowserViewportHostView? {
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

    public var cmuxBrowserViewportUsesHost: Bool {
        guard let host = cmuxBrowserViewportHostView else { return false }
        return superview === host
    }

    public var cmuxBrowserViewportPresentationView: NSView {
        guard cmuxBrowserViewportUsesHost, let host = cmuxBrowserViewportHostView else {
            return self
        }
        return host
    }

    public var cmuxBrowserViewportAttachmentSuperview: NSView? {
        cmuxBrowserViewportPresentationView.superview
    }

    public var cmuxBrowserViewportAttachmentWindow: NSWindow? {
        cmuxBrowserViewportPresentationView.window ?? window
    }

    public var cmuxBrowserViewportExternalRenderHostIsActive: Bool {
        ((objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0) > 0
    }

    func cmuxBeginBrowserViewportExternalRenderHost() {
        let depth = (objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0
        objc_setAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth,
            NSNumber(value: depth + 1),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func cmuxEndBrowserViewportExternalRenderHost() {
        let depth = (objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0
        let nextDepth = max(0, depth - 1)
        objc_setAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth,
            nextDepth > 0 ? NSNumber(value: nextDepth) : nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    public func cmuxIsManagedByExternalRenderHost(relativeTo expectedSuperview: NSView?) -> Bool {
        cmuxBrowserViewportExternalRenderHostIsActive &&
            cmuxBrowserViewportPresentationView.superview !== expectedSuperview
    }

    public var cmuxBrowserViewportContainerBounds: CGRect? {
        cmuxBrowserViewportAttachmentSuperview?.bounds
    }

    var cmuxBrowserViewportLayoutMode: BrowserViewportLayout.Mode {
        (self as? CmuxWebView)?.browserViewportModel?.viewport == nil ? .native : .emulated
    }

    var cmuxBrowserViewportAutoresizingMask: NSView.AutoresizingMask {
        cmuxBrowserViewportLayoutMode == .native ? [.width, .height] : []
    }

    public func cmuxBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: (self as? CmuxWebView)?.browserViewportModel?.viewport,
            pageZoom: Double(pageZoom)
        )
    }

    public func cmuxBrowserViewportLayoutMatches(_ containerBounds: CGRect, epsilon: Double = 0.5) -> Bool {
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
    public func cmuxApplyBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        guard let layout = cmuxBrowserViewportLayout(in: containerBounds) else {
            return nil
        }
        cmuxApplyBrowserViewportLayout(layout)
        return layout
    }

    public func cmuxApplyBrowserViewportLayout(_ layout: BrowserViewportLayout) {
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
    public func cmuxRestoreIntoBrowserViewportHostIfNeeded() -> Bool {
        cmuxBrowserViewportHostView?.restoreWebViewIfNeeded() ?? false
    }

    @discardableResult
    public func cmuxRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe() -> Bool {
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

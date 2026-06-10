import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Browser Panel WebView Rendering State
private var cmuxBrowserPanelNeedsRenderingStateReattachKey: UInt8 = 0
private func browserPanelViewObjectID(_ object: AnyObject?) -> String {
    guard let object else { return "nil" }
    return String(describing: Unmanaged.passUnretained(object).toOpaque())
}

private func browserPanelViewRectDescription(_ rect: NSRect) -> String {
    String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

private extension NSObject {
    @discardableResult
    func browserPanelCallVoidIfAvailable(_ rawSelector: String) -> Bool {
        let selector = NSSelectorFromString(rawSelector)
        guard responds(to: selector) else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let fn = unsafeBitCast(method(for: selector), to: Fn.self)
        fn(self, selector)
        return true
    }
}

extension WKWebView {
    private var cmuxBrowserPanelNeedsRenderingStateReattach: Bool {
        get {
            (objc_getAssociatedObject(self, &cmuxBrowserPanelNeedsRenderingStateReattachKey) as? NSNumber)?
                .boolValue ?? false
        }
        set {
            objc_setAssociatedObject(
                self,
                &cmuxBrowserPanelNeedsRenderingStateReattachKey,
                NSNumber(value: newValue),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    var cmuxBrowserPanelRequiresRenderingStateReattach: Bool {
        cmuxBrowserPanelNeedsRenderingStateReattach
    }

    var cmuxBrowserPanelIsInspectorFrontend: Bool {
        cmuxIsWebInspectorObject(self)
    }

    private func cmuxBrowserPanelApplyRenderingStateRefresh(
        reason: String,
        force: Bool
    ) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.webview.skipInspectorLifecycle " +
                "web=\(browserPanelViewObjectID(self)) reason=\(reason)"
            )
#endif
            return
        }
        guard force || cmuxBrowserPanelNeedsRenderingStateReattach else { return }
        guard window != nil else { return }
        cmuxBrowserPanelNeedsRenderingStateReattach = false

        let firedSelectors = [
            "viewDidUnhide",
            "_enterInWindow",
            "_endDeferringViewInWindowChangesSync",
        ].filter {
            browserPanelCallVoidIfAvailable($0)
        }

        if let scrollView = enclosingScrollView {
            scrollView.needsLayout = true
            scrollView.needsDisplay = true
            scrollView.setNeedsDisplay(scrollView.bounds)
            scrollView.contentView.needsLayout = true
            scrollView.contentView.needsDisplay = true
        }

        needsLayout = true
        needsDisplay = true
        setNeedsDisplay(bounds)

#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "\(force ? "browser.localHost.webview.forceRefresh" : "browser.localHost.webview.reattach") " +
                "web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ",")) " +
                "frame=\(browserPanelViewRectDescription(frame))"
            )
        }
#endif
    }

    func cmuxBrowserPanelNotifyHidden(reason: String) {
        guard !cmuxBrowserPanelIsInspectorFrontend else {
#if DEBUG
            cmuxDebugLog(
                "browser.localHost.webview.skipInspectorHidden " +
                "web=\(browserPanelViewObjectID(self)) reason=\(reason)"
            )
#endif
            return
        }
        cmuxBrowserPanelNeedsRenderingStateReattach = true
        let firedSelectors = ["viewDidHide", "_exitInWindow"].filter {
            browserPanelCallVoidIfAvailable($0)
        }
#if DEBUG
        if !firedSelectors.isEmpty {
            cmuxDebugLog(
                "browser.localHost.webview.hidden web=\(browserPanelViewObjectID(self)) " +
                "reason=\(reason) selectors=\(firedSelectors.joined(separator: ","))"
            )
        }
#endif
    }

    func cmuxBrowserPanelReattachRenderingState(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: false)
    }

    func cmuxBrowserPanelForceRenderingStateRefresh(reason: String) {
        cmuxBrowserPanelApplyRenderingStateRefresh(reason: reason, force: true)
    }
}


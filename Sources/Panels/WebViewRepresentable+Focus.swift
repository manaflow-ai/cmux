import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Focus, Responder Checks & Dismantle
extension WebViewRepresentable {
    #if DEBUG
    static func logDevToolsState(
        _ panel: BrowserPanel,
        event: String,
        generation: Int,
        retryCount: Int,
        details: String? = nil
    ) {
        var line = "browser.devtools event=\(event) panel=\(panel.id.uuidString.prefix(5)) generation=\(generation) retry=\(retryCount) \(panel.debugDeveloperToolsStateSummary())"
        if let details, !details.isEmpty {
            line += " \(details)"
        }
        cmuxDebugLog(line)
    }

    static func objectID(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private static func responderDescription(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(type(of: responder))@\(objectID(responder))"
    }

    private static func rectDescription(_ rect: NSRect) -> String {
        String(format: "%.1f,%.1f %.1fx%.1f", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
    }

    static func attachContext(webView: WKWebView, host: NSView) -> String {
        let hostWindow = host.window?.windowNumber ?? -1
        let webWindow = webView.window?.windowNumber ?? -1
        let firstResponder = (webView.window ?? host.window)?.firstResponder
        return "host=\(objectID(host)) hostWin=\(hostWindow) hostInWin=\(host.window == nil ? 0 : 1) hostFrame=\(rectDescription(host.frame)) hostBounds=\(rectDescription(host.bounds)) oldSuper=\(objectID(webView.superview)) webWin=\(webWindow) webInWin=\(webView.window == nil ? 0 : 1) webFrame=\(rectDescription(webView.frame)) webHidden=\(webView.isHidden ? 1 : 0) fr=\(responderDescription(firstResponder))"
    }
    #endif

    private static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    private static func isLikelyInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if cmuxIsWebInspectorObject(responder) {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if cmuxIsWebInspectorObject(current) {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    private static func firstResponderResignState(
        _ responder: NSResponder?,
        webView: WKWebView
    ) -> (needsResign: Bool, flags: String) {
        let inWebViewChain = responderChainContains(responder, target: webView)
        let inspectorResponder = isLikelyInspectorResponder(responder)
        let needsResign = inWebViewChain || inspectorResponder
        return (
            needsResign: needsResign,
            flags: "frInWebChain=\(inWebViewChain ? 1 : 0) frIsInspector=\(inspectorResponder ? 1 : 0)"
        )
    }

    static func applyFocus(
        panel: BrowserPanel,
        webView: WKWebView,
        nsView: NSView,
        shouldFocusWebView: Bool,
        isPanelFocused: Bool
    ) {
        // Focus handling. Avoid fighting the address bar when it is focused.
        guard let window = nsView.window else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=skip reason=no_window shouldFocus=\(shouldFocusWebView ? 1 : 0) " +
                "panelFocused=\(isPanelFocused ? 1 : 0)"
            )
#endif
            return
        }
        if isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip_webview_intent reason=suppressed_first_responder_chain"
                )
#endif
            } else {
                panel.noteWebViewFocused()
            }
        }
        if shouldFocusWebView {
            if panel.shouldSuppressWebViewFocus() {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=suppressed panelFocused=\(isPanelFocused ? 1 : 0)"
                )
#endif
                return
            }
            if responderChainContains(window.firstResponder, target: webView) {
#if DEBUG
                cmuxDebugLog(
                    "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                    "action=skip reason=already_first_responder_chain"
                )
#endif
                return
            }
            let result = window.makeFirstResponder(webView)
            if result {
                panel.noteWebViewFocused()
            }
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=focus result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        } else if !isPanelFocused && responderChainContains(window.firstResponder, target: webView) {
            // Only force-resign WebView focus when this panel itself is not focused.
            // If the panel is focused but the omnibar-focus state is briefly stale, aggressively
            // clearing first responder here can undo programmatic webview focus (socket tests).
            let result = window.makeFirstResponder(nil)
#if DEBUG
            cmuxDebugLog(
                "browser.focus.content.apply panel=\(panel.id.uuidString.prefix(5)) " +
                "action=resign result=\(result ? 1 : 0) fr=\(responderDescription(window.firstResponder))"
            )
#endif
        }
    }

    static func applyWebViewFirstResponderPolicy(
        panel: BrowserPanel,
        webView: WKWebView,
        isPanelFocused: Bool
    ) {
        guard let cmuxWebView = webView as? CmuxWebView else { return }
        let next = isPanelFocused && !panel.shouldSuppressWebViewFocus()
        if cmuxWebView.allowsFirstResponderAcquisition != next {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.policy panel=\(panel.id.uuidString.prefix(5)) " +
                "web=\(ObjectIdentifier(cmuxWebView)) old=\(cmuxWebView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "new=\(next ? 1 : 0) isPanelFocused=\(isPanelFocused ? 1 : 0) " +
                "suppress=\(panel.shouldSuppressWebViewFocus() ? 1 : 0)"
            )
#endif
        }
        cmuxWebView.allowsFirstResponderAcquisition = next
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.attachGeneration += 1
        clearPortalCallbacks(for: nsView)
        if let panel = coordinator.panel, let host = nsView as? HostContainerView {
            panel.releasePortalHostIfOwned(
                hostId: ObjectIdentifier(host),
                reason: "dismantle"
            )
        }

        guard let webView = coordinator.webView else { return }
        let panel = coordinator.panel

        // If we're being torn down while the WKWebView (or one of its subviews) is first responder,
        // resign it before detaching.
        let window = webView.window ?? nsView.window
        if let window {
            let state = firstResponderResignState(window.firstResponder, webView: webView)
            if state.needsResign {
                #if DEBUG
                if let panel {
                    logDevToolsState(
                        panel,
                        event: "dismantle.resignFirstResponder",
                        generation: coordinator.attachGeneration,
                        retryCount: 0,
                        details: attachContext(webView: webView, host: nsView) + " " + state.flags
                    )
                }
                #endif
                window.makeFirstResponder(nil)
            }
        }

        // SwiftUI can transiently dismantle/rebuild the browser host view during split
        // rearrangement. Do not detach the portal-hosted WKWebView or clear its pane-drop
        // context here; explicit teardown still happens on real web view replacement and
        // panel teardown, and preserving this state lets internal tab drags re-enter the
        // browser pane while SwiftUI churns underneath.
        BrowserWindowPortalRegistry.updateDropZoneOverlay(for: webView, zone: nil)
        coordinator.lastPortalHostId = nil
        coordinator.lastSynchronizedHostGeometryRevision = 0
    }

    func currentPaneDropContext() -> BrowserPaneDropContext? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: panel.workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == panel.workspaceId }),
              let paneId = workspace.paneId(forPanelId: panel.id) else {
            return nil
        }
        return BrowserPaneDropContext(
            workspaceId: panel.workspaceId,
            panelId: panel.id,
            paneId: paneId
        )
    }
}

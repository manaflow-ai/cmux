import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


@MainActor
enum BrowserWindowPortalRegistry {
    struct DebugSnapshot {
        let visibleInUI: Bool
        let containerHidden: Bool
        let frameInWindow: CGRect
    }

    private static var portalsByWindowId: [ObjectIdentifier: WindowBrowserPortal] = [:]
    private static var webViewToWindowId: [ObjectIdentifier: ObjectIdentifier] = [:]

    private static func postRegistryDidChange(for webView: WKWebView) {
        NotificationCenter.default.post(name: .browserPortalRegistryDidChange, object: webView)
    }

    private static func installWindowCloseObserverIfNeeded(for window: NSWindow) {
        guard objc_getAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey) == nil else { return }
        let windowId = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if let window {
                    removePortal(for: window)
                } else {
                    removePortal(windowId: windowId, window: nil)
                }
            }
        }
        objc_setAssociatedObject(
            window,
            &cmuxWindowBrowserPortalCloseObserverKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private static func removePortal(for window: NSWindow) {
        removePortal(windowId: ObjectIdentifier(window), window: window)
    }

    private static func removePortal(windowId: ObjectIdentifier, window: NSWindow?) {
        if let portal = portalsByWindowId.removeValue(forKey: windowId) {
            portal.tearDown()
        }
        webViewToWindowId = webViewToWindowId.filter { $0.value != windowId }

        guard let window else { return }
        if let observer = objc_getAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalCloseObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalKey, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    private static func pruneWebViewMappings(for windowId: ObjectIdentifier, validWebViewIds: Set<ObjectIdentifier>) {
        webViewToWindowId = webViewToWindowId.filter { webViewId, mappedWindowId in
            mappedWindowId != windowId || validWebViewIds.contains(webViewId)
        }
    }

    private static func portal(for window: NSWindow) -> WindowBrowserPortal {
        if let existing = objc_getAssociatedObject(window, &cmuxWindowBrowserPortalKey) as? WindowBrowserPortal {
            portalsByWindowId[ObjectIdentifier(window)] = existing
            installWindowCloseObserverIfNeeded(for: window)
            return existing
        }

        let portal = WindowBrowserPortal(window: window)
        objc_setAssociatedObject(window, &cmuxWindowBrowserPortalKey, portal, .OBJC_ASSOCIATION_RETAIN)
        portalsByWindowId[ObjectIdentifier(window)] = portal
        installWindowCloseObserverIfNeeded(for: window)
        return portal
    }

    static func bind(webView: WKWebView, to anchorView: NSView, visibleInUI: Bool, zPriority: Int = 0) {
        guard let window = anchorView.window else { return }

        let windowId = ObjectIdentifier(window)
        let webViewId = ObjectIdentifier(webView)
        let nextPortal = portal(for: window)

        if let oldWindowId = webViewToWindowId[webViewId],
           oldWindowId != windowId {
            portalsByWindowId[oldWindowId]?.detachWebView(withId: webViewId)
        }

        nextPortal.bind(webView: webView, to: anchorView, visibleInUI: visibleInUI, zPriority: zPriority)
        webViewToWindowId[webViewId] = windowId
        pruneWebViewMappings(for: windowId, validWebViewIds: nextPortal.webViewIds())
        postRegistryDidChange(for: webView)
    }

    static func synchronizeForAnchor(_ anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let portal = portal(for: window)
        portal.synchronizeWebViewForAnchor(anchorView)
    }

    static func scheduleExternalGeometrySynchronize(for window: NSWindow) {
        portalsByWindowId[ObjectIdentifier(window)]?.scheduleExternalGeometrySynchronize()
    }

    static func scheduleExternalGeometrySynchronizeForAllWindows() {
        for portal in portalsByWindowId.values {
            portal.scheduleExternalGeometrySynchronize()
        }
    }

    /// Update visibleInUI/zPriority on an existing portal entry without rebinding.
    /// Called when a bind is deferred because the new host is temporarily off-window.
    static func updateEntryVisibility(for webView: WKWebView, visibleInUI: Bool, zPriority: Int) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateEntryVisibility(forWebViewId: webViewId, visibleInUI: visibleInUI, zPriority: zPriority)
        postRegistryDidChange(for: webView)
    }

    static func isWebView(_ webView: WKWebView, boundTo anchorView: NSView) -> Bool {
        let webViewId = ObjectIdentifier(webView)
        guard let window = anchorView.window else { return false }
        let windowId = ObjectIdentifier(window)
        guard webViewToWindowId[webViewId] == windowId,
              let portal = portalsByWindowId[windowId] else { return false }
        return portal.isWebViewBoundToAnchor(withId: webViewId, anchorView: anchorView)
    }

    static func hide(webView: WKWebView, source: String = "externalHide") {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.hideWebView(withId: webViewId, source: source)
        postRegistryDidChange(for: webView)
    }

    static func discard(
        webView: WKWebView,
        source: String = "externalDiscard",
        preserveCurrentSuperview: Bool = false
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId),
              let portal = portalsByWindowId[windowId] else { return }
        portal.discardWebViewEntry(
            withId: webViewId,
            source: source,
            preserveCurrentSuperview: preserveCurrentSuperview
        )
        postRegistryDidChange(for: webView)
    }

    static func updateDropZoneOverlay(for webView: WKWebView, zone: DropZone?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateDropZoneOverlay(forWebViewId: webViewId, zone: zone)
    }

    static func updatePaneDropContext(for webView: WKWebView, context: BrowserPaneDropContext?) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneDropContext(forWebViewId: webViewId, context: context)
    }

    static func updateSearchOverlay(
        for webView: WKWebView,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateSearchOverlay(forWebViewId: webViewId, configuration: configuration)
    }

    static func updateOmnibarSuggestions(
        for webView: WKWebView,
        configuration: BrowserPortalOmnibarSuggestionsConfiguration?
    ) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updateOmnibarSuggestions(forWebViewId: webViewId, configuration: configuration)
    }

    static func searchOverlayPanelId(for responder: NSResponder, in window: NSWindow) -> UUID? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.searchOverlayPanelId(for: responder)
    }

    @discardableResult
    static func yieldSearchOverlayFocusIfOwned(by panelId: UUID, in window: NSWindow) -> Bool {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return false }
        return portal.yieldSearchOverlayFocusIfOwned(by: panelId)
    }

    static func updatePaneTopChromeHeight(for webView: WKWebView, height: CGFloat) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.updatePaneTopChromeHeight(forWebViewId: webViewId, height: height)
    }

    static func detach(webView: WKWebView) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId.removeValue(forKey: webViewId) else { return }
        portalsByWindowId[windowId]?.detachWebView(withId: webViewId)
        postRegistryDidChange(for: webView)
    }

    static func webViewAtWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> WKWebView? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.webViewAtWindowPoint(windowPoint)
    }

    static func browserPaneDropTargetAtWindowPoint(
        _ windowPoint: NSPoint,
        in window: NSWindow
    ) -> BrowserPaneDropTargetView? {
        let windowId = ObjectIdentifier(window)
        guard let portal = portalsByWindowId[windowId] else { return nil }
        return portal.browserPaneDropTargetAtWindowPoint(windowPoint)
    }

    static func refresh(webView: WKWebView, reason: String) {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return }
        portal.forceRefreshWebView(withId: webViewId, reason: reason)
        postRegistryDidChange(for: webView)
    }

    static func debugSnapshot(for webView: WKWebView) -> DebugSnapshot? {
        let webViewId = ObjectIdentifier(webView)
        guard let windowId = webViewToWindowId[webViewId],
              let portal = portalsByWindowId[windowId] else { return nil }
        return portal.debugSnapshot(forWebViewId: webViewId)
    }

#if DEBUG
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }
#endif
}

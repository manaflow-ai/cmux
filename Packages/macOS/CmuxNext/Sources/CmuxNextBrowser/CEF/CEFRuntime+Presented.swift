import AppKit
import CmuxNextDesign

/// The C entry for Chromium's cursor changes (`CefDisplayHandler::OnCursorChange`, main thread): a presented page's
/// view shows the cursor (its window is headless, so Chromium's own cursor rects show nowhere). A seam adapter: the one
/// place this callback enters the main actor.
struct CEFCursorBridge {
    /// Returns 1 when a presented page's view took the cursor.
    static let callback: CEFShimLibrary.CursorFn = { context, browser, cursor, _ in
        guard let context, let cursor, Thread.isMainThread else { return 0 }
        let address = UInt(bitPattern: context)
        let cursorAddress = UInt(bitPattern: cursor)
        return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
            guard let runtime = CEFRuntime.from(address), let pointer = UnsafeMutableRawPointer(bitPattern: cursorAddress) else { return 0 }
            // Valid only during the call: the page view keeps its own reference.
            let shown = Unmanaged<NSCursor>.fromOpaque(pointer).takeUnretainedValue()
            return runtime.presentedCursorChanged(browser: browser, cursor: shown) ? 1 : 0
        }
    }
}

extension CEFRuntime {
    /// Presented pages (``InTreePages/isPresented``): Chromium's cursor goes to cmux's page views.
    func installPresentedHandlers(_ shim: CEFShimLibrary) {
        shim.setCursorHandler?(CEFCursorBridge.callback)
    }

    /// The presented page view that shows `browser` (a page's, or its docked DevTools'), if any.
    func presentedPageView(browser: Int32) -> CEFHostedPageView? {
        if let tab = tabsByBrowser[browser] {
            let hosting = tab.host.hostView.layerHosting
            return hosting.presents && hosting.browser == browser ? hosting.page : nil
        }
        for tab in tabsByBrowser.values where tab.devToolsController.devToolsBrowserID == browser {
            guard let hosting = tab.devToolsController.views?.host.layerHosting, hosting.presents else { return nil }
            return hosting.page
        }
        return nil
    }

    /// `browser`'s page changed its cursor: its presented page view shows it. False for a page that is not presented
    /// (Chromium handles its own).
    func presentedCursorChanged(browser: Int32, cursor: NSCursor) -> Bool {
        guard let page = presentedPageView(browser: browser), page.input != nil else { return false }
        CEFHostView.trackerStats.presentedCursorChanges += 1
        page.pageCursor = cursor
        return true
    }

    /// The `NSEvent` a Chromium key hook got for a presented page's forwarded key, as cmux's key router saw it
    /// (``CEFForwardedKeys``).
    func originalKeyEvent(_ event: NSEvent) -> NSEvent {
        InTreePages.shared.isPresented ? forwardedKeys.original(for: event) : event
    }
}

import AppKit
import os

/// Faults from the drag callback.
private let pageDragLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef.page-drag")

/// The seam between the shim's C drag callback and the runtime.
enum CEFPageDragCallback {
    /// C entry for a drag a page started (`cmux_shim_set_drag_source_handler`). The remote shim calls it on the
    /// main thread, in the event batch that carried DRAG_START; the data is copied out before the call returns.
    static let source: CEFShimLibrary.DragSourceFn = { context, browser, drag in
        // SAFETY: only the context's address is read; CEFRuntime.from turns it back into the runtime.
        let address = unsafe UInt(bitPattern: context)
        guard address != 0, Thread.isMainThread else {
            pageDragLogger.fault("page drag callback off the main thread or with no runtime; the drag is not shown")
            return
        }
        // SAFETY: `drag` is the fork's cmux_drag_source_t, valid during this call; CEFPageDragData copies it out.
        let data = unsafe drag.flatMap { unsafe CEFPageDragData(fork: $0) }
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            CEFRuntime.from(address)?.pageDragStarted(data, browser: browser)
        }
    }
}

/// Host mode's drag out of a page (feature `chromiumHostDragOut`; task 051 of
/// plans/cmux-next/chrome-parity/p01-process.md). The Chromium Host's page windows never show, so Chromium
/// cannot start a drag session from one: the host sends each drag's data, and the page view of the drag's tab
/// starts the session (``ChromiumHostPageView/beginPageDrag(_:route:)``), as Chrome's browser process has its
/// app shim view start it (`WebContentsViewMac::StartDragging`, content/browser/web_contents/web_contents_view_mac.mm).
/// In process the page window is cmux's own child window and Chromium starts the session itself.
extension CEFRuntime {
    /// Host mode, at the start (the host attached, Chromium not initialized yet): what cmux shows of the
    /// host's pages besides their pixels, its widgets and its pages' drags.
    func startHostPageUI(_ shim: CEFShimLibrary) {
        showHostWidgets(shim)
        installPageDragSource(shim)
    }

    /// Sends the pages' drags to cmux (host mode with the feature on). The remote shim keeps the handler and
    /// gives every host it attaches its state, so a restarted host sends its drags here too.
    func installPageDragSource(_ shim: CEFShimLibrary) {
        guard hostStart?.dragsOut == true else { return }
        // SAFETY: the context is the unretained shared runtime, which lives for the rest of the process once
        // started (as initialize's context); the callback reads only its address.
        unsafe shim.pageDrag.setSourceHandler(CEFPageDragCallback.source, Unmanaged.passUnretained(self).toOpaque())
    }

    /// `browser`'s page started a drag: its tab's page view starts the session when the tab shows, else (or
    /// with data the shim could not read) the page's drag ends now with no drop, so the page can drag again.
    func pageDragStarted(_ data: CEFPageDragData?, browser: Int32) {
        if let data, let host = tabsByBrowser[browser]?.host, host.visibleTab?.browserID == browser,
           let page = host.hostedPageView, page.beginPageDrag(data, route: pageDragRoute(browser: browser)) {
            return
        }
        _ = shim?.pageDrag.sourceEnded(browser, 0, 0, 0, 0, 0)
    }

    /// The shim calls for `browser`'s drag. Every call is a post: none waits for the host.
    func pageDragRoute(browser: Int32) -> ChromiumHostPageDragRoute {
        ChromiumHostPageDragRoute(
            ended: { [weak self] point, screen, operation in
                _ = self?.shim?.pageDrag.sourceEnded(browser, point.x, point.y, screen.x, screen.y, Int32(clamping: operation.rawValue))
            },
            entered: { [weak self] x, y, allowed, modifiers in
                // The page view may show another tab by now: then the drag is not over its own page.
                guard let self, let shim, let host = tabsByBrowser[browser]?.host, host.visibleTab?.browserID == browser else {
                    return false
                }
                _ = shim.pageDrag.targetEnterSource(browser, x, y, Int32(clamping: allowed.rawValue), modifiers)
                return true
            },
            moved: { [weak self] x, y, allowed, modifiers in
                _ = self?.shim?.pageDrag.targetOver(browser, x, y, Int32(clamping: allowed.rawValue), modifiers)
            },
            left: { [weak self] in _ = self?.shim?.pageDrag.targetLeave(browser) },
            dropped: { [weak self] x, y, modifiers in _ = self?.shim?.pageDrag.targetDrop(browser, x, y, modifiers) })
    }
}

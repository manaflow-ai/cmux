import CCEF
import Foundation

/// Browser lifecycle and state callbacks, delivered on the main thread.
public protocol CEFBrowserDelegate: AnyObject {
    func browser(_ browser: CEFBrowser, didUpdateURL url: String)
    func browser(_ browser: CEFBrowser, didUpdateTitle title: String)
    func browser(_ browser: CEFBrowser, didUpdateLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    func browserDidClose(_ browser: CEFBrowser)
}

public extension CEFBrowserDelegate {
    func browser(_ browser: CEFBrowser, didUpdateURL url: String) {}
    func browser(_ browser: CEFBrowser, didUpdateTitle title: String) {}
    func browser(_ browser: CEFBrowser, didUpdateLoadingState isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {}
    func browserDidClose(_ browser: CEFBrowser) {}
}

/// Backs one cef_client_t and its sub-handlers. All sub-handler structs share
/// this object as their Swift owner; each allocation holds its own retain, so
/// the impl lives exactly as long as CEF references any of the structs.
final class CEFClientImpl {
    weak var delegate: CEFBrowserDelegate?
    weak var browser: CEFBrowser?
    /// Fires once when CEF finishes async browser creation.
    var onBrowserCreated: ((CEFBrowser) -> Void)?
    /// Fires after each main-frame load completes.
    var onLoadEnd: ((CEFBrowser) -> Void)?
    /// Strong reference cycle browser<->client is broken in on_before_close.
    private var pendingBrowser: CEFBrowser?

    private var lifeSpanPtr: UnsafeMutablePointer<cef_life_span_handler_t>?
    private var loadPtr: UnsafeMutablePointer<cef_load_handler_t>?
    private var displayPtr: UnsafeMutablePointer<cef_display_handler_t>?

    func makeClientStruct() -> UnsafeMutablePointer<cef_client_t> {
        let ptr = CEFHandler.allocate(cef_client_t.self, object: self)
        ptr.pointee.get_life_span_handler = { selfPtr in
            guard let selfPtr else { return nil }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            let handler = impl.ensureLifeSpanHandler()
            CEFHandler.retain(handler)
            return handler
        }
        ptr.pointee.get_load_handler = { selfPtr in
            guard let selfPtr else { return nil }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            let handler = impl.ensureLoadHandler()
            CEFHandler.retain(handler)
            return handler
        }
        ptr.pointee.get_display_handler = { selfPtr in
            guard let selfPtr else { return nil }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            let handler = impl.ensureDisplayHandler()
            CEFHandler.retain(handler)
            return handler
        }
        return ptr
    }

    /// Drops the allocation reference on each cached sub-handler once the
    /// browser is gone. CEF releases only the references handed out by the
    /// get_*_handler callbacks; without this, the initial +1 from
    /// CEFHandler.allocate keeps every sub-handler struct — and, through the
    /// retain each struct holds on its owner, this client impl — alive
    /// forever after close (same pattern as CEFAppHandlerImpl
    /// .releaseHeldReferences). Called from on_before_close, where CEF still
    /// holds its own reference on the invoking life-span handler, so the
    /// struct cannot be freed mid-callback.
    func releaseCachedSubHandlers() {
        if let ptr = lifeSpanPtr {
            lifeSpanPtr = nil
            cefRelease(UnsafeMutableRawPointer(ptr))
        }
        if let ptr = loadPtr {
            loadPtr = nil
            cefRelease(UnsafeMutableRawPointer(ptr))
        }
        if let ptr = displayPtr {
            displayPtr = nil
            cefRelease(UnsafeMutableRawPointer(ptr))
        }
    }

    func browserWasCreated(_ browser: CEFBrowser) {
        self.browser = browser
        pendingBrowser = browser
        CEFApp.shared.browserDidStart()
        CEFBrowser.registerLiveBrowser(browser)
        onBrowserCreated?(browser)
        onBrowserCreated = nil
    }

    private func ensureLifeSpanHandler() -> UnsafeMutablePointer<cef_life_span_handler_t> {
        if let existing = lifeSpanPtr { return existing }
        let ptr = CEFHandler.allocate(cef_life_span_handler_t.self, object: self)
        ptr.pointee.on_after_created = { selfPtr, browserPtr in
            guard let selfPtr, let browserPtr else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard impl.browser == nil else { return }  // DevTools popups reuse the client
            impl.browserWasCreated(CEFBrowser(retaining: browserPtr, client: impl))
        }
        ptr.pointee.on_before_close = { selfPtr, browserPtr in
            guard let selfPtr, let browserPtr else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard let browser = impl.browser,
                  browser.identifier == browserPtr.pointee.get_identifier?(browserPtr) else { return }
            impl.delegate?.browserDidClose(browser)
            browser.markClosed()
            CEFApp.shared.browserDidStop()
            CEFBrowser.unregisterLiveBrowser(browser)
            impl.pendingBrowser = nil
            impl.releaseCachedSubHandlers()
        }
        lifeSpanPtr = ptr
        return ptr
    }

    private func ensureLoadHandler() -> UnsafeMutablePointer<cef_load_handler_t> {
        if let existing = loadPtr { return existing }
        let ptr = CEFHandler.allocate(cef_load_handler_t.self, object: self)
        ptr.pointee.on_loading_state_change = { selfPtr, _, isLoading, canGoBack, canGoForward in
            guard let selfPtr else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard let browser = impl.browser else { return }
            impl.delegate?.browser(
                browser,
                didUpdateLoadingState: isLoading != 0,
                canGoBack: canGoBack != 0,
                canGoForward: canGoForward != 0
            )
        }
        ptr.pointee.on_load_end = { selfPtr, _, frame, _ in
            guard let selfPtr, let frame, frame.pointee.is_main?(frame) != 0 else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard let browser = impl.browser else { return }
            impl.onLoadEnd?(browser)
        }
        loadPtr = ptr
        return ptr
    }

    private func ensureDisplayHandler() -> UnsafeMutablePointer<cef_display_handler_t> {
        if let existing = displayPtr { return existing }
        let ptr = CEFHandler.allocate(cef_display_handler_t.self, object: self)
        ptr.pointee.on_address_change = { selfPtr, _, frame, url in
            guard let selfPtr, let frame else { return }
            // Only the main frame's address is surfaced.
            guard frame.pointee.is_main?(frame) != 0 else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard let browser = impl.browser, let url = String(cefString: url) else { return }
            impl.delegate?.browser(browser, didUpdateURL: url)
        }
        ptr.pointee.on_title_change = { selfPtr, _, title in
            guard let selfPtr else { return }
            let impl = CEFHandler.object(CEFClientImpl.self, from: selfPtr)
            guard let browser = impl.browser, let title = String(cefString: title) else { return }
            impl.delegate?.browser(browser, didUpdateTitle: title)
        }
        displayPtr = ptr
        return ptr
    }
}

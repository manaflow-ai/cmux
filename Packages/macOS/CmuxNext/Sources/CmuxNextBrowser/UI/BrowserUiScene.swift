#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's Browser scene (Prototypes/UiLayerHost `cmux-ui-browser --shoot DIR --scene
/// browser-chrome`, goal auto-ui-preview-under-60s): the real pane chrome (``BrowserChromeView``: toolbar, address
/// bar, buttons) over an in-memory tab (``MockBrowserEngine``) on a secure page, and the load error page cmux draws
/// over a WebKit tab, each in a window of its own. A push to CmuxNextBrowser gets its before and after from these,
/// built without the app (no CEF, no WebKit page).
@MainActor
public enum BrowserUiScene {
    /// Kept for the shot: the windows draw these.
    static var held: [AnyObject] = []

    /// Opens the scene's windows (each a new window: the shooter draws every window a scene opens).
    public static func show() {
        let engine = MockBrowserEngine(kind: .webkit)
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://cmux.dev/docs/browser")))
        tab.simulate(.titleChanged("Browser - cmux docs"))
        tab.simulate(.securityChanged(.secure))
        tab.simulate(.historyChanged(canGoBack: true, canGoForward: false))
        let chrome = BrowserChromeView(tab: tab)
        open(chrome, title: "Chrome", size: NSSize(width: 960, height: 420))
        held.append(engine)

        let error = LoadErrorView(frame: .zero)
        error.show(BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                    message: "A server with the specified hostname could not be found.",
                                    failingURL: URL(string: "https://staging.cmux.invalid/")))
        open(error, title: "Load error", size: NSSize(width: 640, height: 360))
    }

    private static func open(_ view: NSView, title: String, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Browser: \(title)"
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        held.append(window)
    }
}
#endif

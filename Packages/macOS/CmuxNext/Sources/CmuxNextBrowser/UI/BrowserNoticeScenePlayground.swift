#if DEBUG
public import AppKit

/// DEBUG ONLY: the UI shell's Browser scene (Prototypes/UiLayerHost `cmux-ui-browser --shoot DIR`, scene
/// `browser-notice`): the page's notice (``BrowserNoticeView``, the WebKit fallback's text and its action) on a plain
/// page-sized window, so a push to this module gets a before and after look without an app build or a browser engine.
@MainActor
public final class BrowserNoticeScenePlayground {
    private var window: NSWindow?

    public init() {}

    /// Opens the window, or raises the open one.
    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 240), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Browser Notice Playground"
        window.isReleasedWhenClosed = false
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 240))
        let notice = BrowserNoticeView()
        notice.text = "Chromium could not start, so this tab uses WebKit."
        notice.action = (title: "Retry", run: {})
        page.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24),
            notice.widthAnchor.constraint(lessThanOrEqualTo: page.widthAnchor, constant: -48),
        ])
        window.contentView = page
        window.center()
        return window
    }
}
#endif

import AppKit

/// DevTools in a separate window, hosted in an app-owned NSWindow with an
/// embedded frontend browser (same mechanism as CEFBrowser.openDockedDevTools).
/// This avoids CEF's chrome-style native DevTools window, which is unstable
/// under window churn in CEF 146 (see CEFBrowser.showDevToolsWindow).
/// Requires CEFConfiguration.remoteDebuggingPort != 0.
public final class CEFDevToolsWindow: NSObject, NSWindowDelegate {
    /// The app-owned window hosting the DevTools frontend.
    public let window: NSWindow
    /// The embedded frontend browser; nil until open's completion fires and
    /// after the browser closes.
    public private(set) var browser: CEFBrowser?
    /// Runs on the main thread after the window and its browser are gone.
    public var onClose: (() -> Void)?

    /// Set when the window closes; a browser creation completing afterwards
    /// must tear the browser down instead of resurrecting the window.
    private var isClosed = false
    /// True while the frontend browser's asynchronous creation is in
    /// flight; teardown is deferred to the creation completion so the
    /// delegate/parent view outlive CEF's async creation.
    private var isAwaitingBrowser = false

    /// Instances keep themselves alive while their window is open (and
    /// while a browser creation is still in flight).
    private static var openWindows: Set<CEFDevToolsWindow> = []

    /// Opens a DevTools window for `browser`. Completion runs on the main
    /// thread with nil if the CDP endpoint is disabled or the target can't be
    /// resolved.
    public static func open(
        for browser: CEFBrowser,
        title: String = "DevTools",
        completion: @escaping (CEFDevToolsWindow?) -> Void
    ) {
        guard CEFApp.shared.isDevToolsDockingAvailable else {
            completion(nil)
            return
        }
        browser.devToolsFrontendURL { frontend in
            guard let frontend else {
                completion(nil)
                return
            }
            let devToolsWindow = CEFDevToolsWindow(title: title)
            let container = devToolsWindow.window.contentView as! CEFBrowserContainerView
            openWindows.insert(devToolsWindow)
            devToolsWindow.isAwaitingBrowser = true
            CEFBrowser.create(
                in: container,
                frame: container.bounds,
                url: frontend,
                delegate: devToolsWindow
            ) { devToolsBrowser in
                devToolsWindow.isAwaitingBrowser = false
                guard let devToolsBrowser else {
                    openWindows.remove(devToolsWindow)
                    if devToolsWindow.isClosed {
                        devToolsWindow.onClose?()
                    } else {
                        devToolsWindow.window.close()
                    }
                    completion(nil)
                    return
                }
                if devToolsWindow.isClosed {
                    // The window was dismissed while creation was in
                    // flight: do not resurrect it. Adopt the browser only
                    // to close it; browserDidClose finishes the deferred
                    // teardown (onClose + openWindows removal).
                    devToolsWindow.browser = devToolsBrowser
                    devToolsBrowser.close(force: true)
                    completion(nil)
                    return
                }
                devToolsWindow.browser = devToolsBrowser
                devToolsBrowser.applyDevToolsEmbedderDefaults()
                devToolsWindow.window.makeKeyAndOrderFront(nil)
                completion(devToolsWindow)
            }
        }
    }

    private init(title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = CEFBrowserContainerView()
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.center()
    }

    /// Closes the window; the embedded browser is force-closed from
    /// windowWillClose and `onClose` fires once destruction completes.
    public func close() {
        window.close()
    }

    /// Teardown order matters: Chromium observes the NSWindow that hosts a
    /// browser view, and browser destruction is asynchronous. The window (and
    /// this controller) must stay alive until browserDidClose confirms the
    /// browser is gone; releasing the NSWindow first is a use-after-free
    /// inside Chromium (objc_zombie NSWindow abort). Closing while creation
    /// is still in flight defers teardown to the creation completion.
    public func windowWillClose(_ notification: Notification) {
        isClosed = true
        if let browser {
            browser.close(force: true)
        } else if !isAwaitingBrowser {
            onClose?()
            Self.openWindows.remove(self)
        }
    }
}

extension CEFDevToolsWindow: CEFBrowserDelegate {
    /// Completes teardown once CEF confirms the frontend browser is
    /// destroyed; closes the window if the browser died on its own.
    public func browserDidClose(_ closedBrowser: CEFBrowser) {
        browser = nil
        if window.isVisible {
            window.close()
        }
        onClose?()
        Self.openWindows.remove(self)
    }
}

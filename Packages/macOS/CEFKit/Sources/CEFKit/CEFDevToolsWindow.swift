import AppKit

/// DevTools in a separate window, hosted in an app-owned NSWindow with an
/// embedded frontend browser (same mechanism as CEFBrowser.openDockedDevTools).
/// This avoids CEF's chrome-style native DevTools window, which is unstable
/// under window churn in CEF 146 (see CEFBrowser.showDevToolsWindow).
/// Requires CEFConfiguration.remoteDebuggingPort != 0.
public final class CEFDevToolsWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public private(set) var browser: CEFBrowser?
    public var onClose: (() -> Void)?

    /// Instances keep themselves alive while their window is open.
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
            CEFBrowser.create(
                in: container,
                frame: container.bounds,
                url: frontend,
                delegate: devToolsWindow
            ) { devToolsBrowser in
                guard let devToolsBrowser else {
                    openWindows.remove(devToolsWindow)
                    devToolsWindow.window.close()
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

    public func close() {
        window.close()
    }

    // Teardown order matters: Chromium observes the NSWindow that hosts a
    // browser view, and browser destruction is asynchronous. The window (and
    // this controller) must stay alive until browserDidClose confirms the
    // browser is gone; releasing the NSWindow first is a use-after-free
    // inside Chromium (objc_zombie NSWindow abort).
    public func windowWillClose(_ notification: Notification) {
        if let browser {
            browser.close(force: true)
        } else {
            onClose?()
            Self.openWindows.remove(self)
        }
    }
}

extension CEFDevToolsWindow: CEFBrowserDelegate {
    public func browserDidClose(_ closedBrowser: CEFBrowser) {
        browser = nil
        if window.isVisible {
            window.close()
        }
        onClose?()
        Self.openWindows.remove(self)
    }
}

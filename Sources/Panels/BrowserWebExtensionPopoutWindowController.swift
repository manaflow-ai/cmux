import AppKit
import WebKit

/// Hosts a `windows.create({type: "popup"})` window opened by a web extension —
/// e.g. Bitwarden's passkey-confirmation, unlock, and 2FA popouts.
///
/// The controller is both the `WKWebExtensionWindow` and the owner of the native
/// `NSWindow` + extension-page `WKWebView`; its single tab is a nested adapter.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionPopoutWindowController: NSObject, WKWebExtensionWindow, NSWindowDelegate {
    private static let defaultSize = CGSize(width: 400, height: 600)

    let window: NSWindow
    let webView: WKWebView
    private(set) lazy var tab = Tab(controller: self)
    private weak var support: BrowserWebExtensionSupport?
    private weak var extensionContext: WKWebExtensionContext?

    init(
        configuration: WKWebExtension.WindowConfiguration,
        context: WKWebExtensionContext,
        support: BrowserWebExtensionSupport
    ) {
        self.support = support
        self.extensionContext = context

        let webViewConfiguration = context.webViewConfiguration ?? WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.isInspectable = true

        var frame = configuration.frame
        if frame.isNull || frame.isEmpty || frame.width < 50 || frame.height < 50 {
            frame = CGRect(origin: .zero, size: Self.defaultSize)
        }
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = webView
        if configuration.frame.isNull || configuration.frame.isEmpty {
            window.center()
        }

        super.init()
        window.delegate = self
        window.title = context.webExtension.displayName ?? "Extension"

        if let url = configuration.tabURLs.first {
            webView.load(URLRequest(url: url))
        }
        if configuration.shouldBeFocused {
            NSApp.activate(ignoringOtherApps: false)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    var isKeyWindow: Bool {
        window.isKeyWindow
    }

    func closeFromExtensionOrUser() {
        guard window.delegate === self else { return }
        window.delegate = nil
        support?.popoutDidClose(self)
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window.delegate = nil
        support?.popoutDidClose(self)
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [tab]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        tab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .popup
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window.frame
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        closeFromExtensionOrUser()
        completionHandler(nil)
    }

    // MARK: - Tab

    /// The popout window's single extension-page tab.
    @MainActor
    final class Tab: NSObject, WKWebExtensionTab {
        private weak var controller: BrowserWebExtensionPopoutWindowController?

        init(controller: BrowserWebExtensionPopoutWindowController) {
            self.controller = controller
        }

        func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            controller
        }

        func indexInWindow(for context: WKWebExtensionContext) -> Int {
            0
        }

        func webView(for context: WKWebExtensionContext) -> WKWebView? {
            controller?.webView
        }

        func url(for context: WKWebExtensionContext) -> URL? {
            controller?.webView.url
        }

        func title(for context: WKWebExtensionContext) -> String? {
            controller?.webView.title
        }

        func isSelected(for context: WKWebExtensionContext) -> Bool {
            true
        }

        func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
            guard let webView = controller?.webView else { return true }
            return !webView.isLoading
        }

        func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
            controller?.webView.load(URLRequest(url: url))
            completionHandler(nil)
        }

        func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
            controller?.closeFromExtensionOrUser()
            completionHandler(nil)
        }
    }
}

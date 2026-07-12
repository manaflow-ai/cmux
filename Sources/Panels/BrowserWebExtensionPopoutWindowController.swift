import AppKit
import WebKit

/// Hosts a `windows.create({type: "popup"})` window opened by a web extension —
/// e.g. Bitwarden's passkey-confirmation, unlock, and 2FA popouts.
///
/// The controller is both the `WKWebExtensionWindow` and the owner of the native
/// `NSWindow` + extension-page `WKWebView`; its single tab uses a dedicated adapter.
@available(macOS 15.4, *)
@MainActor
final class BrowserWebExtensionPopoutWindowController: NSObject, WKWebExtensionWindow, NSWindowDelegate {
    private static let defaultSize = CGSize(width: 400, height: 600)

    let window: NSWindow
    let webView: WKWebView
    private(set) lazy var tab = BrowserWebExtensionPopoutTab(controller: self)
    private weak var support: BrowserWebExtensionSupport?
    private(set) weak var extensionContext: WKWebExtensionContext?

    init(
        configuration: WKWebExtension.WindowConfiguration,
        context: WKWebExtensionContext,
        support: BrowserWebExtensionSupport
    ) {
        self.support = support
        self.extensionContext = context

        let webViewConfiguration = context.webViewConfiguration ?? WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
#if DEBUG
        webView.isInspectable = true
#endif

        let requestedFrame = configuration.frame
        let hasUsableOrigin = requestedFrame.origin.x.isFinite && requestedFrame.origin.y.isFinite
        let width = requestedFrame.width.isFinite && requestedFrame.width >= 50 ? requestedFrame.width : Self.defaultSize.width
        let height = requestedFrame.height.isFinite && requestedFrame.height >= 50 ? requestedFrame.height : Self.defaultSize.height
        let frame = CGRect(
            origin: hasUsableOrigin ? requestedFrame.origin : .zero,
            size: CGSize(width: width, height: height)
        )
        let usesFallbackFrame = !hasUsableOrigin
            || !requestedFrame.width.isFinite
            || !requestedFrame.height.isFinite
            || requestedFrame.width < 50
            || requestedFrame.height < 50
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Standalone closable window: the stable identifier opts it into the
        // shared close-shortcut routing (`NSWindow.cmuxShouldOwnCloseShortcut`).
        window.identifier = NSUserInterfaceItemIdentifier("cmux.webExtensionPopout")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = webView
        if usesFallbackFrame {
            window.center()
        }

        super.init()
        window.delegate = self
        window.title = context.webExtension.displayName ?? String(
            localized: "browser.webExtension.action.help",
            defaultValue: "Extension"
        )

        if let url = configuration.tabURLs.first,
           support.canOpenExtensionPopupURL(url, for: context) {
            webView.load(URLRequest(url: url))
        }
        if configuration.shouldBeFocused {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    var isKeyWindow: Bool {
        window.isKeyWindow
    }

    func owns(_ context: WKWebExtensionContext) -> Bool {
        extensionContext === context
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
        owns(context) ? [tab] : []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        owns(context) ? tab : nil
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
        owns(context) ? window.frame : .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        guard owns(context) else { return .null }
        return window.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard owns(context) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 2))
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard owns(context) else {
            completionHandler(NSError(domain: "cmux.webExtension.popup", code: 2))
            return
        }
        closeFromExtensionOrUser()
        completionHandler(nil)
    }

    func canLoadExtensionRequestedURL(_ url: URL) -> Bool {
        guard let extensionContext else { return false }
        return support?.canOpenExtensionPopupURL(url, for: extensionContext) == true
    }

}

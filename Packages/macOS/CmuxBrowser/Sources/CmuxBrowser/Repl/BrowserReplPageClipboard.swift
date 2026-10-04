public import WebKit
import ObjectiveC

/// Keeps page scripts in a tab a REPL session created from writing the
/// system clipboard, and puts what they write on the tab's own clipboard.
///
/// An agent's click, key press or evaluated script gives the page a user
/// gesture, and a page holding one may write the system clipboard (the one
/// the terminal pastes from) through two WebKit paths, neither of which the
/// pasteboard redirect sees or can tell apart by tab:
///
/// - The asynchronous Clipboard API (`navigator.clipboard.write`,
///   `writeText`, a `ClipboardItem` whose data settles later). WebKit's UI
///   process writes those through `+[NSPasteboard generalPasteboard]`, also
///   off the main thread. This is switched off at the engine for the web view
///   (WebKit's `AsyncClipboardAPIEnabled` feature on its `WKPreferences`):
///   `navigator.clipboard`, `Clipboard` and `ClipboardItem` do not exist in
///   any document of the tab, including a frame's initial empty document and
///   a document that was already loaded when the guard was installed.
/// - `document.execCommand("copy" | "cut")`. WebKit's UI process writes those
///   by name (`+[NSPasteboard pasteboardWithName:]`) while it handles the web
///   process's message, which does not say which page sent it, and WebKit
///   has no preference that refuses the command to page script while a
///   gesture is in progress. `page-clipboard.js` replaces `execCommand` in
///   the page's world of every frame before the page's scripts run.
///
/// `page-clipboard.js` also supplies a `navigator.clipboard` and
/// `ClipboardItem` whose writes reach the tab's clipboard through a script
/// message handler (``messageHandlerName``), so a page's Copy button still
/// works for the agent (`page.clipboard.readText()`).
///
/// Residual: WebKit gives user scripts to a document when it commits, not to
/// a frame's initial empty document (an iframe whose `src` is still loading
/// or is a `javascript:` URL, a window a page opened before its first load
/// commits). Same-origin page script can call that document's own
/// `execCommand("copy")` while it holds a gesture, and WebKit's command then
/// writes the system clipboard. Measured on macOS 27.0 (26A428); there is no
/// WebKit setting or UI-process hook that closes it.
@MainActor
public struct BrowserReplPageClipboard {
    /// The source of `Resources/browser-repl/page-clipboard.js`.
    public let shim: String

    public init(shim: String) {
        self.shim = shim
    }

    /// The page-world script message handler `page-clipboard.js` posts to.
    public static let messageHandlerName = "cmuxBrowserReplClipboard"
    /// At most this many items in one write.
    static let maximumItems = 32
    /// At most this many base64 characters in one write (about 48 MB of data).
    static let maximumBase64Characters = 64 << 20
    private static let asyncClipboardFeature = "AsyncClipboardAPIEnabled"
    nonisolated(unsafe) private static var installedKey: UInt8 = 0

    /// Installs the guard on `webView`, once per user content controller:
    /// switches WebKit's asynchronous Clipboard API off and adds
    /// ``shim`` in the page's world of every frame with its
    /// message handler. It stays for the web view's life; documents loaded
    /// from now on get the script, and the API is off in every document at
    /// once.
    ///
    /// - Parameters:
    ///   - onWrite: receives the web view a page wrote from and its items
    ///     (`[["type": String, "base64": String]]`); returns whether a tab's
    ///     clipboard took them. A refusal rejects the page's write.
    /// - Returns: whether WebKit's asynchronous Clipboard API is off. When it
    ///   is not, the guard is incomplete and the caller must fail closed.
    @discardableResult
    public func install(
        on webView: WKWebView,
        refusing: (@MainActor (_ frame: WKFrameInfo) -> String?)? = nil,
        onWrite: @escaping @MainActor (_ webView: WKWebView, _ items: [[String: Any]]) -> Bool
    ) -> Bool {
        let off = Self.disableAsyncClipboardAPI(in: webView.configuration.preferences)
        let controller = webView.configuration.userContentController
        if objc_getAssociatedObject(controller, &Self.installedKey) == nil {
            objc_setAssociatedObject(controller, &Self.installedKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            controller.addScriptMessageHandler(Handler(onWrite: onWrite), contentWorld: .page, name: Self.messageHandlerName)
            controller.addUserScript(
                WKUserScript(
                    source: Self.userScriptSource(shim: shim),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                    in: .page
                )
            )
        }
        return off
    }

    /// `page-clipboard.js` called with a `post` bound, at document start, to
    /// the message handler the page's later scripts cannot replace.
    static func userScriptSource(shim: String) -> String {
        """
        (\(shim))(((handler) => {
          const post = handler && handler.postMessage.bind(handler);
          return (message) => post ? post(message) : Promise.reject(new Error("the tab's clipboard is unavailable"));
        })(globalThis.webkit && globalThis.webkit.messageHandlers && globalThis.webkit.messageHandlers.\(messageHandlerName)));
        """
    }

    /// Whether this WebKit can switch its asynchronous Clipboard API off, the
    /// half of the guard that also covers documents ``shim`` never reaches.
    /// When it cannot, ``install(on:onWrite:)`` leaves the page a native
    /// `navigator.clipboard` there, so a caller must not hand such a web view
    /// to a session as one it created (the driver's `tabs.open` fails with
    /// `unsupported`).
    public static var isSupported: Bool {
        isSupported(featureKey: asyncClipboardFeature)
    }

    static func isSupported(featureKey: String) -> Bool {
        disableAsyncClipboardAPI(in: WKPreferences(), featureKey: featureKey)
    }

    /// Switches WebKit's asynchronous Clipboard API off in `preferences`.
    /// Returns `false` when WebKit's feature list does not have it, or it
    /// stays on.
    @discardableResult
    static func disableAsyncClipboardAPI(in preferences: WKPreferences, featureKey: String = asyncClipboardFeature) -> Bool {
        guard let feature = feature(named: featureKey) else { return false }
        let setter = NSSelectorFromString("_setEnabled:forFeature:")
        let getter = NSSelectorFromString("_isEnabledForFeature:")
        guard preferences.responds(to: setter), preferences.responds(to: getter) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        typealias Get = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        unsafeBitCast(preferences.method(for: setter), to: Set.self)(preferences, setter, false, feature)
        return !unsafeBitCast(preferences.method(for: getter), to: Get.self)(preferences, getter, feature)
    }

    private static func feature(named key: String) -> AnyObject? {
        let selector = NSSelectorFromString("_features")
        guard let method = class_getClassMethod(WKPreferences.self, selector) else { return nil }
        typealias List = @convention(c) (AnyClass, Selector) -> NSArray
        let features = unsafeBitCast(method_getImplementation(method), to: List.self)(WKPreferences.self, selector)
        for case let feature as NSObject in features where (feature.value(forKey: "key") as? String) == key {
            return feature
        }
        return nil
    }

    /// The items of a `page-clipboard.js` message, or `nil` when it is not
    /// `{ items: [{ type, base64 }] }` within the limits.
    static func items(from body: Any) -> [[String: Any]]? {
        guard let message = body as? [String: Any],
              let list = message["items"] as? [Any],
              list.count <= maximumItems else { return nil }
        var total = 0
        var items: [[String: Any]] = []
        for entry in list {
            guard let item = entry as? [String: Any],
                  let type = item["type"] as? String,
                  isClipboardType(type),
                  let base64 = item["base64"] as? String,
                  Data(base64Encoded: base64) != nil else { return nil }
            total += base64.utf8.count
            guard total <= maximumBase64Characters else { return nil }
            items.append(["type": type, "base64": base64])
        }
        return items
    }

    /// A MIME type (`text/plain`) or a web custom format (`web text/x-a`).
    private static func isClipboardType(_ type: String) -> Bool {
        guard !type.isEmpty, type.utf8.count <= 200 else { return false }
        let mime = type.hasPrefix("web ") ? String(type.dropFirst(4)) : type
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let token: (Substring) -> Bool = { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "!#$&^_.+-".contains($0) }
        }
        return parts.count == 2 && token(parts[0]) && token(parts[1])
    }

    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let onWrite: @MainActor (WKWebView, [[String: Any]]) -> Bool

        init(onWrite: @escaping @MainActor (WKWebView, [[String: Any]]) -> Bool) {
            self.onWrite = onWrite
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard let items = BrowserReplPageClipboard.items(from: message.body) else {
                replyHandler(nil, "the clipboard write is not a list of typed items within the size limit")
                return
            }
            guard let webView = message.webView, onWrite(webView, items) else {
                replyHandler(nil, "no browser REPL session holds this tab's clipboard")
                return
            }
            replyHandler(nil, nil)
        }
    }
}

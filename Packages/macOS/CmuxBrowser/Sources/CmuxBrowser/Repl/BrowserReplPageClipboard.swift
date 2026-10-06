public import WebKit
import ObjectiveC

/// The page side of a REPL tab's virtual clipboard: in a tab a session
/// created, page scripts read and write only the tab's clipboard, never the
/// system clipboard (the one the terminal pastes from), also while an
/// agent's click, key or page-world script gives them a user gesture.
///
/// - The asynchronous Clipboard API (`navigator.clipboard`, `Clipboard`,
///   `ClipboardItem`) is switched off at the engine for the web view
///   (WebKit's `AsyncClipboardAPIEnabled` feature on its `WKPreferences`), in
///   every document of the tab, a frame's initial empty document included.
/// - Script paste (`execCommand("paste")`) is switched off at the engine too
///   (`DOMPasteAccessRequestsEnabled`): WebKit then never asks the app for a
///   page's paste access, so no page script reads the system clipboard. A
///   person's Command-V or Edit menu Paste is not a script paste and keeps
///   working.
/// - `execCommand("copy" | "cut")` has no engine switch: WebKit lets any
///   page script run it in a user gesture. `page-clipboard.js` replaces
///   `execCommand` in the page's world of every frame before the page's
///   scripts run and sends the copy to the tab's clipboard through a script
///   message handler (``messageHandlerName``); it also supplies a
///   `navigator.clipboard` and `ClipboardItem` whose writes land there, so a
///   page's Copy button still works for the agent. ``agentWorldGuardSource``
///   does the same for a session's agent world.
///
/// Residual (no WebKit API closes it; measured on macOS 27.0, 26A428):
/// WebKit gives user scripts to a document when it commits, not to a
/// frame's initial empty document (an iframe whose `src` is still loading or
/// is a `javascript:` URL, a window a page opened before its first load
/// commits). Same-origin script, the page's or the agent's, can call that
/// document's own `execCommand("copy")` while it holds a gesture, and
/// WebKit's Copy then writes the system clipboard. WebKit has no per-web-view
/// pasteboard, no setting that refuses script copy in a gesture, and no
/// delegate that sees a pasteboard write, so only a process-wide pasteboard
/// hook could stop it, and cmux has none for the clipboard.
@MainActor
public struct BrowserReplPageClipboard {
    /// The source of `Resources/browser-repl/page-clipboard.js`.
    public let shim: String

    public init(shim: String) {
        self.shim = shim
    }

    /// The guard's callbacks for each tab it was installed for
    /// (``install(on:tab:refusing:onWrite:)``), kept for the tab's life so a
    /// web view that replaces the tab's gets the guard again
    /// (``reinstall(on:tab:)``), also after the session that created the tab
    /// left.
    private var guardedTabs: [UUID: Callbacks] = [:]

    private struct Callbacks {
        let refusing: (@MainActor (_ webView: WKWebView, _ frame: WKFrameInfo) -> String?)?
        let onWrite: @MainActor (_ webView: WKWebView, _ items: [[String: Any]]) -> Bool
    }

    /// ``install(on:refusing:onWrite:)`` on the web view of tab `tab`, which
    /// keeps the guard for its life: a later web view of the tab gets it
    /// through ``reinstall(on:tab:)`` until ``tabClosed(_:)``.
    @discardableResult
    public mutating func install(
        on webView: WKWebView,
        tab: UUID,
        refusing: (@MainActor (_ webView: WKWebView, _ frame: WKFrameInfo) -> String?)? = nil,
        onWrite: @escaping @MainActor (_ webView: WKWebView, _ items: [[String: Any]]) -> Bool
    ) -> Bool {
        if guardedTabs[tab] == nil {
            guardedTabs[tab] = Callbacks(refusing: refusing, onWrite: onWrite)
        }
        return install(on: webView, refusing: refusing, onWrite: onWrite)
    }

    /// Puts the guard on `webView`, which replaced the web view of tab `tab`
    /// (a restore of a page cmux unloaded, a crash recovery: fresh
    /// preferences and user content controller), before it loads.
    /// - Returns: `nil` when the tab never had the guard; else whether it is
    ///   complete (``install(on:refusing:onWrite:)``), and the caller fails
    ///   closed when it is not.
    public func reinstall(on webView: WKWebView, tab: UUID) -> Bool? {
        guard let callbacks = guardedTabs[tab] else { return nil }
        return install(on: webView, refusing: callbacks.refusing, onWrite: callbacks.onWrite)
    }

    /// Forgets tab `tab`, which closed.
    public mutating func tabClosed(_ tab: UUID) {
        guardedTabs[tab] = nil
    }

    /// The page-world script message handler `page-clipboard.js` posts to.
    public static let messageHandlerName = "cmuxBrowserReplClipboard"
    /// At most this many items in one write.
    static let maximumItems = 32
    /// At most this many base64 characters in one write (about 48 MB of data).
    static let maximumBase64Characters = 64 << 20
    private static let asyncClipboardFeature = "AsyncClipboardAPIEnabled"
    private static let domPasteRequestsFeature = "DOMPasteAccessRequestsEnabled"
    nonisolated(unsafe) private static var installedKey: UInt8 = 0

    /// Whether the guard is installed on `webView`'s user content
    /// controller: the web view shows a tab a session created (or did), whose
    /// Copy, Cut and Paste are the tab's virtual clipboard's.
    public static func isInstalled(on webView: WKWebView) -> Bool {
        objc_getAssociatedObject(webView.configuration.userContentController, &installedKey) != nil
    }

    /// Script for the start of a session's agent world in every frame (before
    /// any agent code there): its `execCommand("copy" | "cut" | "paste")`
    /// returns false, so code in that world never runs WebKit's own
    /// clipboard commands with the gesture of an agent's click. The agent
    /// uses `page.clipboard` instead.
    public static let agentWorldGuardSource = """
    (() => {
      const NativeDocument = globalThis.Document;
      const native = NativeDocument && NativeDocument.prototype.execCommand;
      if (!native) return;
      const apply = Reflect.apply;
      const toPrimitiveString = String;
      const toLowerCase = String.prototype.toLowerCase;
      const routed = new Proxy(native, {
        apply(target, thisArg, args) {
          const command = args.length ? toPrimitiveString(args[0]) : "";
          if (typeof command !== "string") return false;
          const name = apply(toLowerCase, command, []);
          if (name === "copy" || name === "cut" || name === "paste") return false;
          return apply(target, thisArg, [command, args[1], args[2]]);
        },
      });
      try {
        Object.defineProperty(NativeDocument.prototype, "execCommand", { value: routed, writable: false, enumerable: true, configurable: false });
      } catch {}
    })();

    """

    /// Installs the guard on `webView`, once per user content controller:
    /// switches WebKit's asynchronous Clipboard API and DOM paste requests
    /// off and adds
    /// ``shim`` in the page's world of every frame with its
    /// message handler. It stays for the web view's life; documents loaded
    /// from now on get the script, and the API is off in every document at
    /// once.
    ///
    /// - Parameters:
    ///   - refusing: why a write from a frame (as WebKit recorded the frame
    ///     that sent it) is refused, or nil; a refusal rejects the page's
    ///     write before `onWrite`. The first install on a controller sets it.
    ///   - onWrite: receives the web view a page wrote from and its items
    ///     (`[["type": String, "base64": String]]`); returns whether a tab's
    ///     clipboard took them. A refusal rejects the page's write.
    /// - Returns: whether WebKit's asynchronous Clipboard API and DOM paste
    ///   requests are off. When they are not, the guard is incomplete and the
    ///   caller must fail closed.
    @discardableResult
    public func install(
        on webView: WKWebView,
        refusing: (@MainActor (_ webView: WKWebView, _ frame: WKFrameInfo) -> String?)? = nil,
        onWrite: @escaping @MainActor (_ webView: WKWebView, _ items: [[String: Any]]) -> Bool
    ) -> Bool {
        let preferences = webView.configuration.preferences
        let off = Self.disableAsyncClipboardAPI(in: preferences)
            && Self.disableAsyncClipboardAPI(in: preferences, featureKey: Self.domPasteRequestsFeature)
        let controller = webView.configuration.userContentController
        if objc_getAssociatedObject(controller, &Self.installedKey) == nil {
            objc_setAssociatedObject(controller, &Self.installedKey, true as NSNumber, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            controller.addScriptMessageHandler(Handler(refusing: refusing, onWrite: onWrite), contentWorld: .page, name: Self.messageHandlerName)
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

    /// Whether this WebKit can switch its asynchronous Clipboard API and DOM
    /// paste requests off, the parts of the guard that also cover documents
    /// ``shim`` never reaches.
    /// When it cannot, ``install(on:onWrite:)`` leaves the page a native
    /// `navigator.clipboard` there, so a caller must not hand such a web view
    /// to a session as one it created (the driver's `tabs.open` fails with
    /// `unsupported`).
    public static var isSupported: Bool {
        isSupported(featureKey: asyncClipboardFeature) && isSupported(featureKey: domPasteRequestsFeature)
    }

    static func isSupported(featureKey: String) -> Bool {
        disableAsyncClipboardAPI(in: WKPreferences(), featureKey: featureKey)
    }

    /// Switches WebKit's feature `featureKey` (by default the asynchronous
    /// Clipboard API) off in `preferences`. Returns `false` when WebKit's
    /// feature list does not have it, or it stays on.
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
        let refusing: (@MainActor (WKWebView, WKFrameInfo) -> String?)?
        let onWrite: @MainActor (WKWebView, [[String: Any]]) -> Bool

        init(
            refusing: (@MainActor (WKWebView, WKFrameInfo) -> String?)?,
            onWrite: @escaping @MainActor (WKWebView, [[String: Any]]) -> Bool
        ) {
            self.refusing = refusing
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
            // The frame that wrote, as WebKit recorded it; a frame the
            // domain policy blocks does not reach the tab's clipboard.
            if let webView = message.webView, let reason = refusing?(webView, message.frameInfo) {
                replyHandler(nil, "this frame may not write the tab's clipboard: \(reason)")
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

public import WebKit

/// Whether a page's document can take typing yet (spec app-screens.md
/// section 3, R59): a user script reports `false` when a document starts
/// and `true` the first time an editable element (the page's primary input)
/// gets focus. The key dispatcher queues printable keys while it is false
/// and delivers them with ``insert(_:)`` when it turns true. Works for every
/// page shown in a WKWebView (React pages, the agent pane); no page code
/// takes part.
@MainActor
public final class PageInputReadiness {
    public static let handlerName = "cmuxInputReady"

    /// True once the current document focused an editable element.
    public private(set) var isReady = false
    /// Runs when ``isReady`` turns true.
    public var onReady: (() -> Void)?
    private weak var webView: WKWebView?

    /// Installs the script and its message handler on `configuration`
    /// before its web view loads anything.
    public init(configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        configuration.userContentController.add(Handler(owner: self), contentWorld: .page, name: Self.handlerName)
    }

    /// The web view the configuration made (``insert(_:)`` types into it).
    public func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    func report(_ ready: Bool) {
        let turnedReady = ready && !isReady
        isReady = ready
        if turnedReady { onReady?() }
    }

    /// Types `text` into the focused editable element as one insertion (its
    /// input events reach the page's own handlers). Returns whether an
    /// editable element had focus.
    public func insert(_ text: String) async -> Bool {
        guard let webView else { return false }
        let inserted = try? await webView.callAsyncJavaScript(Self.insertScript, arguments: ["text": text], in: nil, contentWorld: .page)
        return inserted as? Bool == true
    }

    static let editable = """
        const editable = (el) => !!el && (el.isContentEditable || el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' &&
          !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit'].includes(el.type)));
        """

    static let script = """
        (() => {
          \(editable)
          const post = (ready) => { try { window.webkit.messageHandlers.\(handlerName).postMessage(ready); } catch (_) {} };
          let sent = false;
          post(false);
          const report = () => { if (!sent && editable(document.activeElement)) { sent = true; post(true); } };
          document.addEventListener('focusin', report, true);
          document.addEventListener('DOMContentLoaded', report);
        })();
        """

    static let insertScript = """
        \(editable)
        const el = document.activeElement;
        if (!editable(el)) { return false; }
        return document.execCommand('insertText', false, text);
        """

    /// Holds the readiness weakly (the user content controller retains its handlers).
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var owner: PageInputReadiness?

        init(owner: PageInputReadiness) {
            self.owner = owner
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let ready = message.body as? Bool == true
            MainActor.assumeIsolated { owner?.report(ready) }
        }
    }
}

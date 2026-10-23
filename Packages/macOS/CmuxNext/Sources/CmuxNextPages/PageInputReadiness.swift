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
    /// A list-like control has focus now: a combobox, listbox, menu, tree,
    /// grid or an input that drives one (`aria-activedescendant`,
    /// `aria-autocomplete`). Ctrl-N/P/J/K move its selection (R85).
    public private(set) var isListFocused = false
    /// An editable element has focus now (a text field, a code editor, a
    /// content-editable): bare keys are typing, not bindings.
    public private(set) var isEditableFocused = false
    /// The pointer is over an element that scrolls sideways itself (a wide table or code line in
    /// its own `overflow-x` box): the layout leaves a horizontal scroll there to the page
    /// (``PageWebView`` claims it, `HorizontalScrollClaiming`) instead of scrolling the column strip.
    public private(set) var isPointerOverSidewaysScroller = false
    /// Runs when ``isReady`` turns true.
    public var onReady: (() -> Void)?
    private weak var webView: WKWebView?
    /// Types into a page another engine shows (a Chromium page, ``PageWebView``); nil types into the
    /// attached web view.
    var inserter: ((String) async -> Bool)?

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

    /// One message of the readiness script (`true`/`false`, `{list}` or `{editing}`), from any engine.
    func receive(_ body: Any) {
        if let body = body as? [String: Any] {
            if let list = body["list"] as? Bool { reportList(list) }
            if let editing = body["editing"] as? Bool { reportEditing(editing) }
            if let sideways = body["sideways"] as? Bool { reportSideways(sideways) }
            return
        }
        report(body as? Bool == true)
    }

    func reportList(_ focused: Bool) {
        isListFocused = focused
    }

    func reportEditing(_ focused: Bool) {
        isEditableFocused = focused
    }

    func reportSideways(_ over: Bool) {
        isPointerOverSidewaysScroller = over
    }

    func report(_ ready: Bool) {
        let turnedReady = ready && !isReady
        isReady = ready
        if !ready {
            isListFocused = false
            isEditableFocused = false
            isPointerOverSidewaysScroller = false
        }
        if turnedReady { onReady?() }
    }

    /// Types `text` into the focused editable element as one insertion (its
    /// input events reach the page's own handlers). Returns whether an
    /// editable element had focus.
    public func insert(_ text: String) async -> Bool {
        if let inserter { return await inserter(text) }
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
          let list = false;
          let editing = false;
          post(false);
          const isList = (el) => !!el && el !== document.body && (!!el.closest('[role=listbox],[role=menu],[role=menubar],[role=tree],[role=grid]')
            || el.getAttribute('role') === 'combobox' || el.hasAttribute('aria-activedescendant') || el.hasAttribute('aria-autocomplete'));
          const report = () => {
            if (!sent && editable(document.activeElement)) { sent = true; post(true); }
            const now = isList(document.activeElement);
            if (now !== list) { list = now; post({ list: now }); }
            const typing = editable(document.activeElement);
            if (typing !== editing) { editing = typing; post({ editing: typing }); }
          };
          document.addEventListener('focusin', report, true);
          document.addEventListener('focusout', () => setTimeout(report, 0), true);
          document.addEventListener('DOMContentLoaded', report);
          \(sidewaysScript)
        })();
        """

    /// Reports `{ sideways: Bool }` when the pointer moves onto or off an element that scrolls
    /// sideways itself: an `overflow-x: auto | scroll` box whose content is wider than it. Checked
    /// on each pointer move, wheel and scroll (content can move under a still pointer; the engine
    /// already coalesces these to one a frame), and posted only on a change. The page's root never
    /// counts: it is not a box inside the pane.
    static let sidewaysScript = """
          let pointer = null;
          let sideways = false;
          // Up through shadow roots too: a code card's scroller can be inside one (@pierre/diffs).
          const up = (el) => el.parentElement || (el.parentNode instanceof ShadowRoot ? el.parentNode.host : null);
          const scrollsSideways = (el) => {
            for (; el && el !== document.documentElement && el !== document.body; el = up(el)) {
              if (el.scrollWidth > el.clientWidth + 1) {
                const x = getComputedStyle(el).overflowX;
                if (x === 'auto' || x === 'scroll') return true;
              }
            }
            return false;
          };
          // The deepest element at the point, inside open shadow roots.
          const at = (x, y) => {
            let el = document.elementFromPoint(x, y);
            for (let depth = 0; el && el.shadowRoot && depth < 8; depth++) {
              const inner = el.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === el) break;
              el = inner;
            }
            return el;
          };
          const check = () => {
            const now = !!pointer && scrollsSideways(at(pointer[0], pointer[1]));
            if (now !== sideways) { sideways = now; post({ sideways: now }); }
          };
          const track = (event) => { pointer = [event.clientX, event.clientY]; check(); };
          const options = { capture: true, passive: true };
          document.addEventListener('pointermove', track, options);
          document.addEventListener('wheel', track, options);
          document.addEventListener('scroll', check, options);
          // The pointer left the page: no element is under it.
          document.addEventListener('pointerout', (event) => { if (!event.relatedTarget) { pointer = null; check(); } }, options);
          window.addEventListener('blur', () => { pointer = null; check(); });
        """

    static let insertScript = """
        \(editable)
        const el = document.activeElement;
        if (!editable(el)) { return false; }
        return document.execCommand('insertText', false, text);
        """

    /// Holds the readiness weakly (the user content controller retains its handlers).
    @MainActor
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var owner: PageInputReadiness?

        init(owner: PageInputReadiness) {
            self.owner = owner
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.receive(message.body)
        }
    }
}

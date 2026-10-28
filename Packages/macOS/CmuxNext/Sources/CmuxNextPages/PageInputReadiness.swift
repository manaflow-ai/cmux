public import WebKit
import CmuxNextSettings

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
    public private(set) var focusEpoch = 0
    /// The pointer is over an element that scrolls sideways itself (a wide table or code line in
    /// its own `overflow-x` box): the layout leaves a horizontal scroll there to the page
    /// (``PageWebView`` claims it, `HorizontalScrollClaiming`) instead of scrolling the column strip.
    public private(set) var isPointerOverSidewaysScroller = false
    /// Runs when ``isReady`` turns true.
    public var onReady: (() -> Void)?
    private weak var webView: WKWebView?
    /// Types into a page another engine shows (a Chromium page, ``PageWebView``); nil types into the
    /// attached web view.
    var editor: ((Edit, Int?) async -> Bool)?

    /// One edit of the focused editable element: queued text, or Deletes typed while it was on its way.
    public enum Edit: Equatable, Sendable {
        case insert(String)
        case deleteBackward(Int)

        /// The script body that makes this edit (`editable` and the element check come first).
        var script: String {
            switch self {
            case .insert(let text):
                "return document.execCommand('insertText', false, \(JSONValue.string(text).compactText));"
            case .deleteBackward(let count):
                // One `delete` per key, as the keys would: each is an input event the page's handlers see.
                "for (let i = 0; i < \(max(0, count)); i += 1) { if (document.activeElement !== el || window.__cmuxInputFocusEpoch !== cmuxEditEpoch || (token !== null && el.__cmuxInputEditToken !== token)) { return false; } if (!document.execCommand('delete', false)) { return false; } } return true;"
            }
        }
    }

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

    /// A stable token for the editable element that owns a queued edit sequence. The page stores
    /// it on that element; later Deletes refuse a different focused element, so an async insert
    /// cannot move the queued edits into another field.
    var editToken = UUID().uuidString

    /// One message of the readiness script (`true`/`false`, `{list}` or `{editing}`), from any engine.
    func receive(_ body: Any) {
        if let body = body as? [String: Any] {
            if let epoch = body["epoch"] as? Int { focusEpoch = epoch }
            if let ready = body["ready"] as? Bool { report(ready) }
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
    public func insert(_ text: String, expectedEpoch: Int? = nil) async -> Bool {
        await apply(.insert(text), expectedEpoch: expectedEpoch)
    }

    /// Deletes `count` characters before the caret of the focused editable element, one Delete
    /// each: the Deletes typed while queued text was still being inserted (``insert(_:)``).
    public func deleteBackward(_ count: Int, expectedEpoch: Int? = nil) async -> Bool {
        guard count > 0 else { return true }
        return await apply(.deleteBackward(count), expectedEpoch: expectedEpoch)
    }

    private func apply(_ edit: Edit, expectedEpoch: Int?) async -> Bool {
        if let editor { return await editor(edit, expectedEpoch) }
        guard let webView else { return false }
        let done = try? await webView.callAsyncJavaScript(Self.editScript(edit, token: editToken, expectedEpoch: expectedEpoch), arguments: [:], in: nil, contentWorld: .page)
        return done as? Bool == true
    }

    /// A function body that makes `edit` in the focused editable element; false when none has focus.
    static func editScript(_ edit: Edit, token: String? = nil, expectedEpoch: Int? = nil) -> String {
        let tokenLiteral = token.map { JSONValue.string($0).compactText } ?? "null"
        let epochCheck = expectedEpoch.map { "if (window.__cmuxInputFocusEpoch !== \($0)) { return false; }" } ?? ""
        let allowsNewToken: Bool = if case .insert = edit { true } else { false }
        let tokenCheck = allowsNewToken
            ? "if (prior !== undefined && prior !== token) { return false; }"
            : "if (prior !== token) { return false; }"
        return """
        \(editable)
        const el = document.activeElement;
        if (!editable(el)) { return false; }
        \(epochCheck)
        const cmuxEditEpoch = window.__cmuxInputFocusEpoch;
        const token = \(tokenLiteral);
        if (token !== null) {
          const prior = el.__cmuxInputEditToken;
          \(tokenCheck)
          el.__cmuxInputEditToken = token;
        }
        \(edit.script)
        """
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
          let epoch = 0;
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
          document.addEventListener('focusin', () => {
            epoch += 1;
            window.__cmuxInputFocusEpoch = epoch;
            try { window.webkit.messageHandlers.\(handlerName).postMessage({ epoch }); } catch (_) {}
            report();
          }, true);
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

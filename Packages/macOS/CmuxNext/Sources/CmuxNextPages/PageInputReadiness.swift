public import WebKit
import CmuxNextBrowserCore
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

    /// True once the current document focused an editable element, while no ``awaitFocus(on:)`` waits.
    public private(set) var isReady = false
    /// The current document focused an editable element.
    private var documentReady = false
    /// The command target ``awaitFocus(on:)`` waits for, and its bound.
    private var awaitedTarget: String?
    private var awaitedBound: Task<Void, Never>?
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
    /// The command target (`data-cmux-command-focus`) of the element with focus now; nil for any other element.
    public private(set) var commandFocus: String?
    /// The longest ``awaitFocus(on:)`` keeps the page's keys when the focus it waits for does not come.
    public var focusWaitLimit: Duration = .milliseconds(500)
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

    /// A command the page got (Cmd-F's find) focuses the element marked `data-cmux-command-focus="<target>"` in the
    /// page's own turn. Until it has focus, or ``focusWaitLimit``, the page is not ready for typing, so keys typed
    /// meanwhile wait for that element (the key router's type-ahead).
    public func awaitFocus(on target: String) {
        guard commandFocus != target, Self.focusWaitMode != "off" else { return }
        awaitedTarget = target
        awaitedBound?.cancel()
        awaitedBound = nil
        // Before the document loaded (a fresh launch), the page runs the command once it loads: the wait is for that
        // document, and its bound counts from the document's first focus (``report(_:)``).
        if documentReady { startFocusWaitBound() }
        trace("wait \(target) document=\(documentReady) focus=\(commandFocus ?? "-")")
        update()
    }

    private func startFocusWaitBound() {
        let limit = focusWaitLimit
        // task-owner: one-shot bound on this wait; the focus it waits for, a new document or the next wait cancels it
        awaitedBound = Task { [weak self] in
            // wakeup-allow: one-shot bound on a page's command focus, cancelled when the focus comes first
            do { try await Task.sleep(for: limit) } catch { return }
            self?.endFocusWait("limit")
        }
    }

    /// The focus ``awaitFocus(on:)`` waited for came (or its bound passed): the keys kept for it go on.
    private func endFocusWait(_ why: String) {
        guard awaitedTarget != nil else { return }
        awaitedTarget = nil
        awaitedBound?.cancel()
        awaitedBound = nil
        trace("wait end \(why)")
        update()
    }

    /// ``isReady`` from the document's readiness and the command wait; ``onReady`` runs when it turns true.
    private func update() {
        let ready = documentReady && awaitedTarget == nil
        let turnedReady = ready && !isReady
        isReady = ready
        if turnedReady { onReady?() }
    }

    /// `CMUX_DEBUG_FOCUS_WAIT` in Debug builds: `off` waits for no command focus, `epoch` also ends a wait at any focus
    /// change (the first fix, kept to measure against); anything else waits for the command's own field.
    #if DEBUG || CMUX_BENCH_HOOKS
    static let focusWaitMode = ProcessInfo.processInfo.environment["CMUX_DEBUG_FOCUS_WAIT"] ?? "field"
    /// Notes a readiness event in the app's input journal (`debug.journal`).
    func trace(_ event: String) { BrowserLifecycleTrace.shared.record(BrowserTabID(rawValue: "readiness"), event) }
    #else
    static let focusWaitMode = "field"
    func trace(_ event: String) {}
    #endif

    /// A stable token for the editable element that owns a queued edit sequence. The page stores
    /// it on that element; later Deletes refuse a different focused element, so an async insert
    /// cannot move the queued edits into another field.
    var editToken = UUID().uuidString

    /// One message of the readiness script (`true`/`false`, `{list}` or `{editing}`), from any engine.
    func receive(_ body: Any) {
        if let body = body as? [String: Any] {
            #if DEBUG || CMUX_BENCH_HOOKS
            trace("page \(body.keys.sorted().map { "\($0)=\(body[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))")
            #endif
            if let epoch = body["epoch"] as? Int {
                if Self.focusWaitMode == "epoch", epoch != focusEpoch { endFocusWait("epoch") }
                focusEpoch = epoch
            }
            if let target = body["commandFocus"] as? String {
                commandFocus = target.isEmpty ? nil : target
                if let awaited = awaitedTarget, commandFocus == awaited { endFocusWait("focus") }
            }
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
        documentReady = ready
        if ready, awaitedTarget != nil, awaitedBound == nil { startFocusWaitBound() }
        if !ready {
            // A new document: a wait for the last one's field ends with it. A wait made before any document (no bound
            // yet) is for this one.
            if awaitedBound != nil {
                awaitedTarget = nil
                awaitedBound?.cancel()
                awaitedBound = nil
            }
            commandFocus = nil
            isListFocused = false
            isEditableFocused = false
            isPointerOverSidewaysScroller = false
        }
        update()
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
          // The element the epoch counts focus for: the same element focused again (its window got
          // focus) is not a focus move, so text queued for it still lands (1 in 150 New Tab tries lost it).
          let focused = null;
          const describe = (el) => !el ? '-' : (el.tagName || '?').toLowerCase() + (el.id ? '#' + el.id : '') + (el.isContentEditable ? '[editable]' : '');
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
          // The command target a focused element is marked as (`data-cmux-command-focus`, Cmd-F's find field); "" for none.
          const commandFocus = (el) => (el && el.closest && el.closest('[data-cmux-command-focus]')?.getAttribute('data-cmux-command-focus')) || '';
          let command = '';
          document.addEventListener('focusin', (event) => {
            const now = commandFocus(event.target);
            if (event.target !== focused) {
              focused = event.target;
              epoch += 1;
              window.__cmuxInputFocusEpoch = epoch;
              command = now;
              try { window.webkit.messageHandlers.\(handlerName).postMessage({ epoch, commandFocus: now\(debugFocusFields) }); } catch (_) {}
            } else if (now !== command) {
              command = now;
              post({ commandFocus: now });
            }
            report();
          }, true);
          \(debugKeyScript)
          document.addEventListener('focusout', () => setTimeout(() => {
            // Focus fell to no element (the find bar closed under its field): the command target is gone too.
            const now = commandFocus(document.activeElement);
            if (now !== command) { command = now; post({ commandFocus: now }); }
            report();
          }, 0), true);
          document.addEventListener('DOMContentLoaded', report);
          \(sidewaysScript)
        })();
        """

    #if DEBUG || CMUX_BENCH_HOOKS
    /// Debug builds: each focus message names its element, and each printable key names the element it reached.
    static let debugFocusFields = ", el: describe(event.target)"
    static let debugKeyScript = """
          document.addEventListener('keydown', (event) => { if (event.key && event.key.length === 1) post({ keyTarget: describe(event.target) }); }, true);
        """
    #else
    static let debugFocusFields = ""
    static let debugKeyScript = ""
    #endif

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

extension PageInputReadiness {
    /// Runs `work` each time the page turns ready for typing (it replaces ``onReady``), and now when it already is.
    public func whenReady(_ work: @escaping () -> Void) {
        onReady = work
        if isReady { work() }
    }
}

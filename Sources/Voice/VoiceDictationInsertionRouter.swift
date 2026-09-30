import AppKit
import CmuxFoundation
import CmuxVoice
import WebKit

/// Pins the focused input target when dictation starts and inserts finalized
/// segments into it for the rest of the session.
///
/// Route priority (see `DictationInsertionRouteResolver`): a native text
/// responder wins, then editable web content in the key `WKWebView` (agent
/// composer, browser pane), then the focused terminal surface. Terminals get
/// text through the paste path (the same one as Cmd+V and `cmux paste`), so
/// a program with bracketed paste on receives each segment as one paste and
/// can never mistake dictated text for keystrokes or a submit. The target is
/// pinned per session on purpose: moving focus mid-dictation never scatters
/// text across panes, and if the pinned target goes away the session ends.
///
/// When the target is an agent prompt (a terminal running a coding agent, or
/// web content such as the agent chat composer) and the setting is on,
/// spoken fillers are removed first (`String.removingDictationFillers`).
@MainActor
final class VoiceDictationInsertionRouter: DictationTextInserting {
    private static let javaScriptEvaluationTimeout: TimeInterval = 2

    /// Resolves the focused terminal of the active workspace across window
    /// contexts; injected from the composition root.
    private let focusedTerminalTarget: @MainActor () -> VoiceDictationTerminalTarget?
    /// Whether agent-prompt cleanup is on; read once per session.
    private let cleanUpAgentPrompts: () -> Bool
    private let resolver = DictationInsertionRouteResolver()
    private var cleansText = false
    private var nextExplicitTerminalTarget: VoiceDictationTerminalTarget?

    private weak var pinnedTextView: NSTextView?
    private weak var pinnedTextField: NSTextField?
    private weak var pinnedWebView: WKWebView?
    private weak var pinnedTerminalPanel: TerminalPanel?
    private var activeRoute: DictationInsertionRoute?

    private static let pinWebEditableTargetScript = """
    (() => {
      let active = document.activeElement;
      while (active?.shadowRoot?.activeElement) {
        active = active.shadowRoot.activeElement;
      }
      if (!active || active.disabled || active.readOnly) return false;
      const tag = (active.tagName || "").toLowerCase();
      const inputType = String(active.type || "").toLowerCase();
      const autocomplete = String(active.autocomplete || "").toLowerCase();
      if (inputType === "password" || autocomplete.includes("password")) return false;
      let target = null;
      if (tag === "textarea" || (tag === "input" && inputType !== "hidden")) {
        target = active;
      } else if (active.isContentEditable) {
        target = active;
      } else {
        target = active.closest?.('[contenteditable]:not([contenteditable="false"])');
      }
      if (!target) return false;
      window.__cmuxVoiceDictationTarget = target;
      return true;
    })()
    """

    init(
        focusedTerminalTarget: @escaping @MainActor () -> VoiceDictationTerminalTarget?,
        cleanUpAgentPrompts: @escaping () -> Bool
    ) {
        self.focusedTerminalTarget = focusedTerminalTarget
        self.cleanUpAgentPrompts = cleanUpAgentPrompts
    }

    /// Supplies the pane selected by a UI action before the asynchronous
    /// controller startup begins. This avoids resolving global focus again
    /// after a scheduler hop.
    func setNextExplicitTerminalTarget(_ target: VoiceDictationTerminalTarget) {
        nextExplicitTerminalTarget = target
    }

    func beginSession() async -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let textView = responder as? NSTextView
        let directTextField = responder as? NSTextField
        let fieldEditorOwner = textView.flatMap(Self.verifiedFieldEditorOwner)
        let isUnverifiedFieldEditor = textView?.isFieldEditor == true
            && fieldEditorOwner == nil
        let isSecureNativeInput = responder is NSSecureTextField
            || fieldEditorOwner is NSSecureTextField
        let webView = (responder as? NSView).flatMap(Self.enclosingWebView(of:))
        let terminalTarget = nextExplicitTerminalTarget ?? focusedTerminalTarget()
        nextExplicitTerminalTarget = nil
        let terminalPanel = terminalTarget?.panel
        let nativeTextView = textView ?? directTextField?.currentEditor() as? NSTextView
        let nativeTextInputIsEditable = webView == nil
            && !isUnverifiedFieldEditor
            && (textView?.isEditable == true
                || (directTextField?.isEditable == true && nativeTextView != nil))
            && !isSecureNativeInput
        let webViewIsEditable = if let webView {
            await Self.pinWebViewEditableTarget(webView)
        } else {
            false
        }

        guard let route = resolver.route(
            firstResponderIsTextInput: nativeTextInputIsEditable,
            firstResponderIsWebView: webViewIsEditable,
            // A browser responder is an exclusive focus domain. If its active
            // element is read-only, secure, or otherwise rejected by the
            // probe, fail closed instead of typing into a stale workspace PTY.
            hasFocusedTerminalSurface: webView == nil
                && !isUnverifiedFieldEditor
                && !isSecureNativeInput
                && terminalPanel != nil
        ) else { return false }

        activeRoute = route
        switch route {
        case .nativeTextResponder:
            pinnedTextView = nativeTextView
            pinnedTextField = fieldEditorOwner
                ?? (directTextField?.isEditable == true ? directTextField : nil)
        case .webViewEditable:
            pinnedWebView = webView
        case .terminalSurface:
            pinnedTerminalPanel = terminalPanel
        }
        // Native text fields are cmux UI (rename, palette, find), never an
        // agent prompt. Web content is the agent chat composer or a page
        // input; both read better without fillers.
        let targetIsAgentPrompt = switch route {
        case .nativeTextResponder: false
        case .webViewEditable: true
        case .terminalSurface: terminalTarget?.isAgentPrompt == true
        }
        cleansText = targetIsAgentPrompt && cleanUpAgentPrompts()
        return true
    }

    func insertFinalizedText(_ delta: String) async -> Bool {
        let text = cleansText ? Self.cleaned(delta) : delta
        guard !text.isEmpty else { return true }
        switch activeRoute {
        case .nativeTextResponder:
            guard let textView = pinnedTextView, textView.window != nil else { return false }
            if textView.isFieldEditor {
                guard let textField = pinnedTextField,
                      textField.currentEditor() === textView else { return false }
            }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        case .webViewEditable:
            guard let webView = pinnedWebView, webView.window != nil,
                  let literal = text.javaScriptStringLiteral else { return false }
            // Wait for the JavaScript completion before acknowledging the
            // segment. Otherwise a rejected final insertion can be reported
            // as success and the controller will settle while text is lost.
            return await Self.evaluateBoolean(
                """
                (() => {
                  const target = window.__cmuxVoiceDictationTarget;
                  if (!target || !target.isConnected || target.disabled || target.readOnly) {
                    return false;
                  }
                  target.focus();
                  return Boolean(document.execCommand('insertText', false, \(literal)));
                })()
                """,
                in: webView
            )
        case .terminalSurface:
            guard let panel = pinnedTerminalPanel else { return false }
            return panel.sendTextResult(text).accepted
        case nil:
            return false
        }
    }

    func endSession() {
        if let webView = pinnedWebView {
            webView.evaluateJavaScript(
                "window.__cmuxVoiceDictationTarget = null;",
                completionHandler: nil
            )
        }
        pinnedTextView = nil
        pinnedTextField = nil
        pinnedWebView = nil
        pinnedTerminalPanel = nil
        activeRoute = nil
        cleansText = false
    }

    /// Cleans one delta while keeping its leading separator space, which
    /// `DictationTranscript` adds between segments.
    static func cleaned(_ delta: String) -> String {
        let body = delta.drop { $0 == " " }
        let cleanedBody = String(body).removingDictationFillers
        guard !cleanedBody.isEmpty else { return "" }
        return String(delta.prefix(delta.count - body.count)) + cleanedBody
    }

    private static func pinWebViewEditableTarget(_ webView: WKWebView) async -> Bool {
        guard webView.window != nil else { return false }
        return await evaluateBoolean(Self.pinWebEditableTargetScript, in: webView)
    }

    private static func evaluateBoolean(_ script: String, in webView: WKWebView) async -> Bool {
        do {
            let result = try await BrowserScreenshotJavaScriptRequest(
                webView: webView,
                timeout: javaScriptEvaluationTimeout
            ).evaluate(script: script)
            if let value = result as? Bool { return value }
            if let value = result as? NSNumber { return value.boolValue }
            return false
        } catch {
            return false
        }
    }

    private static func enclosingWebView(of view: NSView) -> WKWebView? {
        var current: NSView? = view
        while let candidate = current {
            if let webView = candidate as? WKWebView { return webView }
            current = candidate.superview
        }
        return nil
    }

    /// Resolves a field editor's owner through the live `currentEditor()`
    /// relationship. A field editor's delegate is commonly an external
    /// delegate object, so treating the delegate as the owning field can route
    /// dictation into a terminal or misclassify secure fields.
    private static func verifiedFieldEditorOwner(_ editor: NSTextView) -> NSTextField? {
        guard editor.isFieldEditor else { return nil }

        if let owner = cmuxFieldEditorOwnerView(editor) as? NSTextField,
           owner.currentEditor() === editor {
            return owner
        }

        guard let root = editor.window?.contentView else { return nil }
        return findTextFieldOwningEditor(editor, in: root)
    }

    private static func findTextFieldOwningEditor(
        _ editor: NSTextView,
        in view: NSView
    ) -> NSTextField? {
        if let field = view as? NSTextField,
           field.currentEditor() === editor {
            return field
        }
        for subview in view.subviews {
            if let owner = findTextFieldOwningEditor(editor, in: subview) {
                return owner
            }
        }
        return nil
    }
}

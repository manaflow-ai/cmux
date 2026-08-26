import AppKit
import CmuxFoundation
import CmuxVoice
import WebKit

/// Pins the focused input target when dictation starts and types finalized
/// segments into it for the rest of the session.
///
/// Route priority (see `DictationInsertionRouteResolver`): a native text
/// responder wins, then editable web content in the key `WKWebView` (agent
/// composer, browser pane), then the focused terminal surface via the
/// typed-input PTY path. The target is pinned per session on purpose:
/// moving focus mid-dictation never scatters text across panes, and if the
/// pinned target goes away the session ends.
@MainActor
final class VoiceDictationInsertionRouter: DictationTextInserting {
    private static let javaScriptEvaluationTimeout: TimeInterval = 2

    /// Resolves the focused terminal panel of the active workspace across
    /// window contexts; injected from the composition root.
    private let focusedTerminalPanel: () -> TerminalPanel?
    private let resolver = DictationInsertionRouteResolver()

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
      let target = null;
      if (tag === "textarea" || (tag === "input" && active.type !== "hidden")) {
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

    init(focusedTerminalPanel: @escaping () -> TerminalPanel?) {
        self.focusedTerminalPanel = focusedTerminalPanel
    }

    func beginSession() async -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let textView = responder as? NSTextView
        let fieldEditorOwner = textView?.isFieldEditor == true
            ? textView?.delegate as? NSTextField
            : nil
        let webView = (responder as? NSView).flatMap(Self.enclosingWebView(of:))
        let terminalPanel = focusedTerminalPanel()
        let nativeTextInputIsEditable = textView?.isEditable == true
            && (textView?.isFieldEditor != true || fieldEditorOwner != nil)
        let webViewIsEditable = if let webView {
            await Self.pinWebViewEditableTarget(webView)
        } else {
            false
        }

        guard let route = resolver.route(
            firstResponderIsTextInput: nativeTextInputIsEditable,
            firstResponderIsWebView: webViewIsEditable,
            hasFocusedTerminalSurface: terminalPanel != nil
        ) else { return false }

        activeRoute = route
        switch route {
        case .nativeTextResponder:
            pinnedTextView = textView
            pinnedTextField = fieldEditorOwner
        case .webViewEditable:
            pinnedWebView = webView
        case .terminalSurface:
            pinnedTerminalPanel = terminalPanel
        }
        return true
    }

    func insertFinalizedText(_ text: String) async -> Bool {
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
            return panel.sendInputResult(text).accepted
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
}

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
    /// Resolves the focused terminal panel of the active workspace across
    /// window contexts; injected from the composition root.
    private let focusedTerminalPanel: () -> TerminalPanel?
    private let resolver = DictationInsertionRouteResolver()

    private weak var pinnedTextView: NSTextView?
    private weak var pinnedWebView: WKWebView?
    private weak var pinnedTerminalPanel: TerminalPanel?
    private var activeRoute: DictationInsertionRoute?

    init(focusedTerminalPanel: @escaping () -> TerminalPanel?) {
        self.focusedTerminalPanel = focusedTerminalPanel
    }

    func beginSession() -> Bool {
        let responder = NSApp.keyWindow?.firstResponder
        let textView = responder as? NSTextView
        let webView = (responder as? NSView).flatMap(Self.enclosingWebView(of:))
        let terminalPanel = focusedTerminalPanel()

        guard let route = resolver.route(
            firstResponderIsTextInput: textView != nil,
            firstResponderIsWebView: webView != nil,
            hasFocusedTerminalSurface: terminalPanel != nil
        ) else { return false }

        activeRoute = route
        switch route {
        case .nativeTextResponder:
            pinnedTextView = textView
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
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        case .webViewEditable:
            guard let webView = pinnedWebView, webView.window != nil,
                  let literal = text.javaScriptStringLiteral else { return false }
            // Wait for the JavaScript completion before acknowledging the
            // segment. Otherwise a rejected final insertion can be reported
            // as success and the controller will settle while text is lost.
            return await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(
                    "Boolean(document.execCommand('insertText', false, \(literal)))"
                ) { result, error in
                    let commandSucceeded: Bool
                    if let value = result as? Bool {
                        commandSucceeded = value
                    } else if let value = result as? NSNumber {
                        commandSucceeded = value.boolValue
                    } else {
                        commandSucceeded = false
                    }
                    continuation.resume(
                        returning: error == nil && commandSucceeded
                    )
                }
            }
        case .terminalSurface:
            guard let panel = pinnedTerminalPanel else { return false }
            return panel.sendInputResult(text).accepted
        case nil:
            return false
        }
    }

    func endSession() {
        pinnedTextView = nil
        pinnedWebView = nil
        pinnedTerminalPanel = nil
        activeRoute = nil
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

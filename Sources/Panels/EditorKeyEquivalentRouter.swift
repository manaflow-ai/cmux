import AppKit
import WebKit

/// Routes editor key equivalents to a Monaco webviews page so the app's
/// standard Edit menu can never shadow the editor: the configurable
/// `saveFilePreview` shortcut (including chorded bindings) triggers a save,
/// and the standard undo/redo chords drive Monaco's own model undo/redo
/// (WKWebView's native `undo:` does nothing useful for a Monaco buffer).
///
/// One shared implementation backs every Monaco host — the browser-hosted
/// `cmux edit` surface and the markdown panel's edit mode — so both speak the
/// same save/undo/redo entrypoint.
@MainActor
final class EditorKeyEquivalentRouter {
    /// Pending first stroke of a chorded save shortcut.
    private var saveChordPrefixPending = false

    /// Clears chord state, e.g. when the hosting page navigates away.
    func resetChord() {
        saveChordPrefixPending = false
    }

    /// Returns whether the event was consumed.
    ///
    /// - Parameters:
    ///   - isBufferDirty: gates the save shortcut; hosts whose page is always
    ///     an editor (the markdown panel) pass `true` so the shortcut is
    ///     consumed even when clean (the page's save controller no-ops).
    ///   - isEditorActive: gates undo/redo routing so hosts with arbitrary
    ///     pages (the browser) keep default behavior outside editor pages.
    func handle(event: NSEvent, webView: WKWebView, isBufferDirty: Bool, isEditorActive: Bool) -> Bool {
        // Save: configurable shortcut, gated on a dirty buffer / chord prefix.
        if isBufferDirty || saveChordPrefixPending {
            let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
            var saveMatched = false
            if shortcut.hasChord {
                if saveChordPrefixPending {
                    saveChordPrefixPending = false
                    if let secondStroke = shortcut.secondStroke, secondStroke.matches(event: event) {
                        saveMatched = true
                    }
                } else if shortcut.firstStroke.matches(event: event) {
                    saveChordPrefixPending = true
                    return true
                }
            } else if shortcut.matches(event: event) {
                saveMatched = true
            }
            if saveMatched {
                webView.evaluateJavaScript("window.__cmuxEditorRequestSave && window.__cmuxEditorRequestSave();")
                return true
            }
        }
        // Undo / redo: only when an editor page is live in this webview.
        guard isEditorActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard command, !flags.contains(.option), !flags.contains(.control) else { return false }
        if key == "z", !shift {
            webView.evaluateJavaScript("window.__cmuxEditorUndo && window.__cmuxEditorUndo();")
            return true
        }
        if (key == "z" && shift) || key == "y" {
            webView.evaluateJavaScript("window.__cmuxEditorRedo && window.__cmuxEditorRedo();")
            return true
        }
        return false
    }
}

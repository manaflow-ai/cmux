import AppKit
import WebKit

/// WKWebView hosting the markdown panel's Monaco edit surface. Forwards
/// pointer-down for pane focus (mirroring the other panel webviews) and gives
/// the coordinator first refusal on key equivalents so the configurable save
/// shortcut and undo/redo reach Monaco instead of the app's Edit menu.
@MainActor
final class MarkdownEditorWebView: WKWebView {
    var onPointerDown: (() -> Void)?
    var onEditorKeyEquivalent: ((NSEvent) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onEditorKeyEquivalent?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

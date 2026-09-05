import AppKit
import WebKit

/// Paints math while leaving terminal focus, selection, and scrolling with Ghostty.
@MainActor
final class TerminalLatexWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

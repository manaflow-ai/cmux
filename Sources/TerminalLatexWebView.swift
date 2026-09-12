import AppKit
import WebKit

/// Paints math while leaving terminal focus, selection, and scrolling with Ghostty.
@MainActor
final class TerminalLatexWebView: WKWebView {
    /// Keeps keyboard focus in the underlying terminal.
    override var acceptsFirstResponder: Bool { false }

    /// Sends all pointer interaction to the underlying terminal.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

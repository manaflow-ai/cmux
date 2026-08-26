import AppKit
import WebKit

/// Non-interactive `WKWebView` used exclusively by the video background layer.
///
/// The host container already refuses hit-testing; these overrides are the
/// belt-and-braces guarantee that the video layer can never take clicks or
/// keyboard focus away from the terminal.
@MainActor
final class VideoBackgroundWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
}

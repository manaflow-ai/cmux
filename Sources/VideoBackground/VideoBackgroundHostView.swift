import AppKit

/// Passthrough container for the window's video background layer.
///
/// Installed in the window's theme frame below `contentView`, so every
/// interactive surface draws and hit-tests above it. Returning `nil` from
/// `hitTest` short-circuits AppKit before it descends into WebKit's own
/// subviews, keeping the video strictly non-interactive.
@MainActor
final class VideoBackgroundHostView: NSView {
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

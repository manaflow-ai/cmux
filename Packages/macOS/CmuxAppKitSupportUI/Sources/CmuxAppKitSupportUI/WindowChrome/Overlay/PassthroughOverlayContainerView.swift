public import AppKit

/// A transparent window-level overlay container that never intercepts mouse
/// events, letting every click fall through to the views beneath it.
///
/// Shared by the passthrough overlays installed above the window content
/// (tmux workspace-pane indicators, file-drop chrome). Overlays that need to
/// capture clicks while presented use their own container that gates
/// ``AppKit/NSView/hitTest(_:)`` on a flag instead.
@MainActor
public final class PassthroughOverlayContainerView: NSView {
    /// Creates a passthrough overlay container.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isOpaque: Bool { false }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

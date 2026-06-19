public import AppKit

/// AppKit user-interface identifier stamped on the command-palette overlay
/// container so the window hierarchy can find it.
public let commandPaletteOverlayContainerIdentifier = NSUserInterfaceItemIdentifier("cmux.commandPalette.overlay.container")

/// The window-level container that hosts the command-palette overlay.
///
/// Unlike a plain passthrough overlay, this container conditionally captures
/// mouse events: it ignores clicks (so they reach the terminal/browser
/// beneath) until the palette is presented, at which point ``capturesMouseEvents``
/// flips on and ``AppKit/NSView/hitTest(_:)`` routes through normally.
@MainActor
public final class CommandPaletteOverlayContainerView: NSView {
    /// Whether the container intercepts mouse events. `false` lets clicks fall
    /// through to the views beneath the overlay; `true` while the palette is up.
    public var capturesMouseEvents = false

    /// Creates a command-palette overlay container.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturesMouseEvents else { return nil }
        return super.hitTest(point)
    }
}

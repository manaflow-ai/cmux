public import AppKit

/// The one overlay child window of a main window (`WindowOverlayHost`):
/// transparent and borderless, the size of its parent, ordered above every
/// page window. It ignores the mouse except over interactive overlays, and
/// becomes key only while a modal overlay shows.
public final class OverlayHostPanel: NSPanel {
    /// The layout overlay planes (focus rings, drop zones) live here, below the presented overlays.
    public let planeContainer = NSView()
    /// Presented overlays, above the planes.
    let overlayContainer = OverlayContainerView()
    var acceptsKey = false
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        let root = NSView()
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        for layer in [planeContainer, overlayContainer as NSView] {
            layer.wantsLayer = true
            layer.autoresizingMask = [.width, .height]
            root.addSubview(layer)
        }
        contentView = root
        setAccessibilityElement(false)
    }

    override public var canBecomeKey: Bool { acceptsKey }
    override public var canBecomeMain: Bool { false }

    /// Escape in a modal overlay.
    override public func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

/// Holds presented overlays; flipped so overlay frames read top-down in tests and logs.
final class OverlayContainerView: NSView {
    override var isFlipped: Bool { false }
}

/// A scrim over the whole window under a dimming overlay.
final class OverlayScrimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // The scrim takes clicks so nothing below reacts while a modal shows.
    override func mouseDown(with event: NSEvent) {}
}

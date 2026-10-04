public import AppKit

/// The one overlay child window of a main window (`WindowOverlayHost`):
/// transparent and borderless, the size of its parent, ordered above every
/// page window. It ignores the mouse except over interactive overlays, and
/// becomes key only while a modal overlay shows.
public final class OverlayHostPanel: NSPanel {
    /// The layout overlay planes (focus rings, drop zones) live here, below the presented overlays.
    public let planeContainer = NSView()
    /// Presented overlays, above the planes, one container per layer (bottom to top).
    let paneContainer = OverlayContainerView()
    let windowContainer = OverlayContainerView()
    let modalContainer = OverlayContainerView()
    /// The full-size container used for bounds and coordinates.
    var overlayContainer: OverlayContainerView { windowContainer }

    func container(for layer: OverlayLayer) -> OverlayContainerView {
        switch layer {
        case .pane: paneContainer
        case .window: windowContainer
        case .modal: modalContainer
        }
    }
    var acceptsKey = false
    var onCancel: (() -> Void)?
    /// Tab (true) or Shift-Tab (false) inside a modal overlay: the host moves focus within it.
    var onCycleKeyView: ((Bool) -> Bool)?

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
        for layer in [planeContainer, paneContainer, windowContainer, modalContainer] as [NSView] {
            layer.wantsLayer = true
            layer.autoresizingMask = [.width, .height]
            root.addSubview(layer)
        }
        contentView = root
        setAccessibilityElement(false)
    }

    override public var canBecomeKey: Bool { acceptsKey }
    override public var canBecomeMain: Bool { false }

    override public func selectNextKeyView(_ sender: Any?) {
        if onCycleKeyView?(true) != true { super.selectNextKeyView(sender) }
    }

    override public func selectPreviousKeyView(_ sender: Any?) {
        if onCycleKeyView?(false) != true { super.selectPreviousKeyView(sender) }
    }

    /// Escape in a modal overlay.
    override public func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

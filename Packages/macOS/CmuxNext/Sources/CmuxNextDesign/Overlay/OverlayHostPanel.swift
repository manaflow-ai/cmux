public import AppKit
public import CmuxNextInput
public import CmuxNextWakeups

/// The overlay child window of a main window (`WindowOverlayHost`), the
/// fallback home of its top layer while Chromium page child windows show:
/// transparent and borderless, the size of its parent, ordered above every
/// page window. It ignores the mouse except over interactive overlays, and
/// becomes key only while a modal overlay shows.
public final class OverlayHostPanel: NSPanel, HoverFrameInputHosting {
    /// The host's top layer, which this panel holds while overlays draw here.
    public let topLayer: OverlayTopLayerView
    /// The layout overlay planes (focus rings, drop zones) live here, below the presented overlays.
    public var planeContainer: NSView { topLayer.planeContainer }
    /// Presented overlays, above the planes, one container per layer (bottom to top).
    var paneContainer: OverlayContainerView { topLayer.paneContainer }
    var windowContainer: OverlayContainerView { topLayer.windowContainer }
    var modalContainer: OverlayContainerView { topLayer.modalContainer }
    /// The full-size container used for bounds and coordinates.
    var overlayContainer: OverlayContainerView { topLayer.overlayContainer }

    func container(for layer: OverlayLayer) -> OverlayContainerView { topLayer.container(for: layer) }
    var acceptsKey = false
    var onCancel: (() -> Void)?
    /// Tab (true) or Shift-Tab (false) inside a modal overlay: the host moves focus within it.
    var onCycleKeyView: ((Bool) -> Bool)?
    /// A mouse event that reached the panel; true when the host handled it
    /// (passed it on to the parent window).
    var onMouseEvent: ((NSEvent) -> Bool)?
    /// Its parent's frame-aligned hover input (``WindowOverlayHost/hoverFrames``): its views hover once per frame.
    public internal(set) var hoverFrameInput: FrameInputCoalescers?

    init(topLayer: OverlayTopLayerView) {
        self.topLayer = topLayer
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // While it takes the mouse, moves reach it, so it can let go outside the interactive regions.
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        // The host mounts the top layer here while overlays draw in the panel.
        let root = NSView()
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        contentView = root
        setAccessibilityElement(false)
    }

    override public var canBecomeKey: Bool { acceptsKey }

    override public func sendEvent(_ event: NSEvent) {
        if onMouseEvent?(event) == true { return }
        super.sendEvent(event)
    }
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

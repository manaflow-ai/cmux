public import AppKit

/// The one view a window's presented overlays live in (``WindowOverlayHost``), in window coordinates.
///
/// Bottom to top: the layout overlay planes (focus rings, drop zones), then one container per
/// ``OverlayLayer`` (`.pane`, `.window`, `.modal`), with the agent cursor between the window and modal
/// containers. The host keeps it in one of two places:
///
/// - On top of the window's content view (feature `overlayTopLayer`, no page child window shows):
///   the window's top layer, as Blink's top layer paints dialogs and popovers above the rest of the
///   document (`third_party/blink/renderer/core/dom/document.cc`, `Document::AddToTopLayer`) and a
///   `views::View` paints its last child on top (`ui/views/view.cc`, `View::PaintChildren`). It takes
///   the mouse only where ``acceptsMouse`` says (an interactive overlay, a modal's region, an agent
///   cursor tag); every other point falls through to the views below in the same hit test.
/// - In the overlay child panel (``OverlayHostPanel``), the fallback while Chromium page child
///   windows show, which draw above everything in the parent window.
public final class OverlayTopLayerView: NSView {
    /// The layout overlay planes live here, below the presented overlays (panel only: in the window
    /// they stay in their layout root).
    public let planeContainer = NSView()
    let paneContainer = OverlayContainerView()
    let windowContainer = OverlayContainerView()
    let modalContainer = OverlayContainerView()
    /// Whether a point (this view's coordinates, the window's) takes the mouse while the view is the
    /// window's top layer. In the panel the panel's own routing decides (`WindowOverlayHost+Mouse`).
    var acceptsMouse: ((NSPoint) -> Bool)?
    /// Escape reached the view through the responder chain (a modal's control did not take it).
    var onCancel: (() -> Void)?
    /// Tab (true) or Shift-Tab (false) reached the view: the host moves focus within the modal.
    var onCycleKeyView: ((Bool) -> Bool)?
    /// The view's size changed (the window resized): the host places its overlays again.
    var onResize: (() -> Void)?

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        for container in [planeContainer, paneContainer, windowContainer, modalContainer] as [NSView] {
            container.wantsLayer = true
            container.autoresizingMask = [.width, .height]
            container.frame = bounds
            addSubview(container)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The full-size container used for bounds and coordinates.
    var overlayContainer: OverlayContainerView { windowContainer }

    func container(for layer: OverlayLayer) -> OverlayContainerView {
        switch layer {
        case .pane: paneContainer
        case .window: windowContainer
        case .modal: modalContainer
        }
    }

    /// Whether the view is in the window itself, not in the overlay panel.
    var isWindowTopLayer: Bool { window != nil && !(window is OverlayHostPanel) }

    override public func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    /// In the window, only interactive overlays take the mouse; the rest of the window is hit below.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard isWindowTopLayer else { return super.hitTest(point) }
        let local = superview.map { convert(point, from: $0) } ?? point
        guard acceptsMouse?(local) == true else { return nil }
        return super.hitTest(point)
    }

    /// A blocking region never drags the window (its titlebar runs under the full-size content).
    override public var mouseDownCanMoveWindow: Bool { false }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A click or scroll in a blocking region the overlays did not take ends here: nothing below reacts.
    override public func mouseDown(with event: NSEvent) {}
    override public func rightMouseDown(with event: NSEvent) {}
    override public func otherMouseDown(with event: NSEvent) {}
    override public func mouseUp(with event: NSEvent) {}
    override public func rightMouseUp(with event: NSEvent) {}
    override public func otherMouseUp(with event: NSEvent) {}
    override public func mouseDragged(with event: NSEvent) {}
    override public func scrollWheel(with event: NSEvent) {}

    /// Escape and Tab that a modal's control passed up the responder chain (a dialog view handles its
    /// own first); in the panel they reach the panel's `cancelOperation` and key view loop instead.
    override public func keyDown(with event: NSEvent) {
        guard isWindowTopLayer else { return super.keyDown(with: event) }
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch event.keyCode {
        case 53 where plain && onCancel != nil:
            onCancel?()
        case 48 where plain && onCycleKeyView?(!event.modifierFlags.contains(.shift)) == true:
            break
        default:
            super.keyDown(with: event)
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        if isWindowTopLayer, let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}

/// A main window whose overlay host draws in its own top layer (feature `overlayTopLayer`) while no page
/// child window shows; read once, when the window's ``WindowOverlayHost`` is made.
@MainActor
public protocol OverlayTopLayerHosting: NSWindow {
    /// Whether overlays draw in the window's top layer instead of the overlay child panel.
    var overlaysInTopLayer: Bool { get }
}

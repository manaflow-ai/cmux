import AppKit

@MainActor
final class UsageTipsOverlayContainerView: NSView {
    weak var interactiveView: NSView?
    var interactiveContentInsets = NSEdgeInsetsZero

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveView,
              !isHidden,
              !interactiveView.isHidden else { return nil }
        let containerPoint = convert(point, from: superview)
        let localPoint = interactiveView.convert(containerPoint, from: self)
        let bounds = interactiveView.bounds
        let interactiveBounds = NSRect(
            x: bounds.minX + interactiveContentInsets.left,
            y: bounds.minY + interactiveContentInsets.bottom,
            width: max(0, bounds.width - interactiveContentInsets.left - interactiveContentInsets.right),
            height: max(0, bounds.height - interactiveContentInsets.top - interactiveContentInsets.bottom)
        )
        guard interactiveBounds.contains(localPoint) else { return nil }
        return interactiveView.hitTest(containerPoint)
    }
}

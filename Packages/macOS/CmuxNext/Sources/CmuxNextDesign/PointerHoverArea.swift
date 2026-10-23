import AppKit

/// The tracking area one ``PointerHover`` keeps on its view, held by exact object until
/// ``remove()``.
///
/// A `PointerHover` deinit is nonisolated and reads only `Sendable` state, so it cannot hold
/// the `NSTrackingArea` itself. It holds this main-actor class instead and passes it to the main
/// thread (`MainDelivery().run { area.remove() }`): inline when the hover is released on main,
/// a hop from any other thread. The exact area leaves the view, never another owner's area that
/// reuses a freed address.
///
/// AppKit does not retain a tracking area's owner. The owner is a small forwarder that this
/// holder retains and that reads its hover weakly: until the area is off the view, an enter or
/// exit reaches a live object, which drops it once the hover is gone.
@MainActor
final class PointerHoverArea {
    private weak var view: NSView?
    private let area: NSTrackingArea
    private let owner: Forwarder

    /// Makes the area for `view`; nothing is on the view until ``install(for:)``.
    init(view: NSView, options: NSTrackingArea.Options) {
        self.view = view
        owner = Forwarder()
        area = NSTrackingArea(rect: .zero, options: options, owner: owner)
    }

    /// Adds the area to the view; its enters and exits go to `hover` while it lives.
    func install(for hover: PointerHover) {
        owner.hover = hover
        view?.addTrackingArea(area)
    }

    /// Takes the area off the view (a view in deallocation reads nil here, and its areas go with it).
    func remove() {
        view?.removeTrackingArea(area)
    }
}

/// The tracking area's owner: forwards enters and exits to the hover while it lives.
///
/// AppKit sends a tracking area's owner `mouseEntered:` and `mouseExited:`. This owner is not
/// an NSResponder, so the selectors must be named: a bare `@objc` exports `mouseEnteredWith:`,
/// and the first enter raised NSInvalidArgumentException in `_dispatchMouseEntered:` (cx-2mp6).
@MainActor
private final class Forwarder: NSObject {
    weak var hover: PointerHover?

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { hover?.mouseEntered(with: event) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hover?.mouseExited(with: event) }
}

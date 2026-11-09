public import AppKit

/// A view that can take its subtree off screen while it stays in its window: a parked workspace
/// (`WindowRootView.withdraw`). Hidden parking sets `isHidden` as well, and AppKit's hide hooks do the
/// work; this flag is the same fact for parking that does not hide (alpha parking keeps the parked
/// layer tree in the render server, so a switch back sends WindowServer nothing new). Views below read
/// ``AppKit/NSView/isParkedOrHasParkedAncestor`` beside `isHiddenOrHasHiddenAncestor`, and hear the
/// change through ``ParkingObserver``.
@MainActor public protocol ParkingContainer: NSView {
    /// Off screen while in the window: parked.
    var isParkedOffScreen: Bool { get }
    /// `view` is about to show below this parked container (a tab switch in a parked pane,
    /// ``AppKit/NSView/willShowContent(_:)``). A container that parks by paint only, while its views stay
    /// unhidden, hides first when `view` does not stop on parking (a page's window orders out on a hide only).
    func parkedContentWillShow(_ view: NSView)
}

extension ParkingContainer {
    public func parkedContentWillShow(_ view: NSView) {}
}

/// A view that stops work while a container above it is parked (drawing, event monitors, frames).
@MainActor public protocol ParkingObserver: NSView {
    /// A container above changed ``ParkingContainer/isParkedOffScreen`` while this view was not hidden.
    func parkingDidChange()
}

extension NSView {
    /// This view or an ancestor is parked (``ParkingContainer``). One walk up the superviews; read on
    /// transitions (park, show, a window change), never per frame.
    public var isParkedOrHasParkedAncestor: Bool {
        var view: NSView? = self
        while let current = view {
            if let container = current as? any ParkingContainer, container.isParkedOffScreen { return true }
            view = current.superview
        }
        return false
    }

    /// `view` is about to show in this view's subtree (unhidden or added: a tab switch). Each parked container from
    /// here up hears it first (``ParkingContainer/parkedContentWillShow(_:)``). One walk up the superviews, on a
    /// switch, never per frame.
    public func willShowContent(_ view: NSView) {
        var current: NSView? = self
        while let container = current {
            if let parking = container as? any ParkingContainer, parking.isParkedOffScreen { parking.parkedContentWillShow(view) }
            current = container.superview
        }
    }

    /// Tells each ``ParkingObserver`` in this subtree that parking changed. A hidden subtree is skipped:
    /// it is off screen anyway, and AppKit's unhide re-checks it, so hidden parking walks nothing.
    public func notifyParkingChange() {
        guard !isHidden else { return }
        (self as? any ParkingObserver)?.parkingDidChange()
        for subview in subviews { subview.notifyParkingChange() }
    }
}

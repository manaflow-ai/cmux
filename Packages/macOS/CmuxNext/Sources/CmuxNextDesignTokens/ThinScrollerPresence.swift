package import CoreGraphics

/// Whether a ``ThinScroller``'s knob shows and how wide it is: a pure state machine, so the fade and
/// the grow are tested without a window, a pointer or a clock.
///
/// macOS overlay rules (Lawrence 2026-10-23, msg 11494: "auto-fades away, and grows bigger on
/// near-hover so it's easier to grab"): the knob shows while the view scrolls and for
/// ``ThinScroller/restDelay`` after, while it is dragged, and while the pointer is near the
/// scroller's edge. It is wide (``ThinScroller/expandedKnobThickness``) while the pointer is near or
/// it is dragged, thin otherwise.
package struct ThinScrollerPresence: Equatable {
    /// False keeps the knob shown whenever the content overflows (the old behavior, opt-out).
    package var autoHides = true
    /// True: the pointer near the edge reveals a knob that was hidden. False (the terminal, whose
    /// last column is the terminal's): it only holds and widens a knob already shown.
    package var revealsNearPointerAtRest = true

    /// The view scrolled and the rest delay has not passed yet.
    package private(set) var scrolledRecently = false
    /// The pointer is within ``ThinScroller/nearDistance`` of the scroller's trailing edge.
    package private(set) var pointerNear = false
    /// The pointer is near and holds the knob shown (see ``revealsNearPointerAtRest``).
    package private(set) var hovering = false
    /// The knob is being dragged.
    package private(set) var dragging = false

    /// The knob is drawn (when the content overflows).
    package var shown: Bool { !autoHides || scrolledRecently || dragging || hovering }
    /// The knob is drawn wide.
    package var expanded: Bool { shown && (hovering || dragging) }

    /// The view scrolled: show now; the caller arms the rest delay and calls ``rested()``.
    package mutating func scrolled() {
        scrolledRecently = true
        if pointerNear { hovering = true }
    }

    /// The rest delay passed with no new scroll.
    package mutating func rested() { scrolledRecently = false }

    /// The pointer moved near the edge or away from it.
    package mutating func pointer(near: Bool) {
        pointerNear = near
        if !near { hovering = false } else if revealsNearPointerAtRest || shown { hovering = true }
    }

    /// A knob drag began or ended. The end counts as a scroll, so the knob stays a moment.
    package mutating func drag(_ active: Bool) {
        dragging = active
        if !active { scrolled() }
    }

    package init(autoHides: Bool = true, revealsNearPointerAtRest: Bool = true, scrolledRecently: Bool = false, pointerNear: Bool = false, hovering: Bool = false, dragging: Bool = false) {
        self.autoHides = autoHides
        self.revealsNearPointerAtRest = revealsNearPointerAtRest
        self.scrolledRecently = scrolledRecently
        self.pointerNear = pointerNear
        self.hovering = hovering
        self.dragging = dragging
    }
}

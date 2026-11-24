package import CoreGraphics

/// Whether a ``ThinScroller``'s knob shows and how wide it is: a pure state machine, so the fade and
/// the grow are tested without a window, a pointer or a clock.
///
/// Overlay rules (Lawrence 2026-10-23, msg 11494: "auto-fades away, and grows bigger on
/// near-hover so it's easier to grab"; Leo 2026-11-22: "when hovering your mouse to the sidebar, do
/// you want to see the thumb? claude code, you dont see it... unless you scroll first. hovering
/// only doesnt show"): the knob shows while the view scrolls and for ``ThinScroller/restDelay``
/// after, and while it is dragged. The pointer never shows a hidden knob: it only holds and widens
/// one a scroll already showed (``ThinScroller/expandedKnobThickness``), so a press next to a
/// resize handle is never the hover's surprise.
package struct ThinScrollerPresence: Equatable {
    /// False keeps the knob shown whenever the content overflows (the old behavior, opt-out).
    package var autoHides = true

    /// The view scrolled and the rest delay has not passed yet.
    package private(set) var scrolledRecently = false
    /// The pointer is in the scroller's grab zone (``ThinScroller/grabZone``) at its trailing edge.
    package private(set) var pointerNear = false
    /// The pointer is near and holds the knob shown (only a knob a scroll showed).
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
        if !near { hovering = false } else if shown { hovering = true }
    }

    /// A knob drag began or ended. The end counts as a scroll, so the knob stays a moment.
    package mutating func drag(_ active: Bool) {
        dragging = active
        if !active { scrolled() }
    }

    package init(autoHides: Bool = true, scrolledRecently: Bool = false, pointerNear: Bool = false, hovering: Bool = false, dragging: Bool = false) {
        self.autoHides = autoHides
        self.scrolledRecently = scrolledRecently
        self.pointerNear = pointerNear
        self.hovering = hovering
        self.dragging = dragging
    }
}

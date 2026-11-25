import AppKit

/// A press on a ``ThinScroller``: the knob drag, a track press that pages or jumps, and how each
/// scrolls the scroll view. The scroller tracks its own presses so a press anywhere in its
/// ``ThinScroller/grabZone`` behaves the same (AppKit's tracker answered only on its own knob and
/// slot parts, and only while its own overlay knob showed), and the knob keeps the point it was
/// grabbed by under the pointer, 1:1, wherever the pointer goes until the release.
extension ThinScroller {
    /// How long a held track press waits before it pages again, and how often it pages after
    /// (AppKit's `NSScrollerButtonDelay` and `NSScrollerButtonPeriod` defaults).
    static let pageRepeatDelay: TimeInterval = 0.5
    static let pageRepeatPeriod: TimeInterval = 0.05

    /// The knob slot and knob along the axis, measured from the top (a sideways scroller's: from
    /// the leading end), in this scroller's points.
    var track: ThinScrollerTrack {
        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        guard !isHorizontal else {
            return ThinScrollerTrack(slotStart: slot.minX, slotLength: slot.width, knobStart: knob.minX, knobLength: knob.width)
        }
        return ThinScrollerTrack(slotStart: fromTop(slot), slotLength: slot.height, knobStart: fromTop(knob), knobLength: knob.height)
    }

    /// Where `event` is along the axis, from the top (the leading end), in this scroller's points.
    /// Off the bar too: only the axis counts.
    func axisPosition(of event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        if isHorizontal { return point.x }
        return isFlipped ? point.y : bounds.maxY - point.y
    }

    /// Tracks the press `down` until the button comes up: a press on the knob drags it, one on the
    /// track pages toward the press while it is held, or jumps the knob there (``jumpsToClickedSpot``,
    /// Option inverting it) and drags it from there.
    ///
    /// - Parameters:
    ///   - down: The press.
    ///   - nextEvent: The next event of a mask, waiting until a date; nil when none came by then.
    ///     The app passes the window's event queue.
    /// - Returns: The release, or nil when the press ended without one.
    @discardableResult
    func track(from down: NSEvent, nextEvent: (NSEvent.EventTypeMask, Date) -> NSEvent?) -> NSEvent? {
        guard overflows else { return waitForRelease(nextEvent) }
        let scrollView = superview as? NSScrollView
        if let scrollView { notificationCenter.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView) }
        defer {
            if let scrollView { notificationCenter.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView) }
        }
        let start = track
        let pressed = axisPosition(of: down)
        let part = start.part(at: pressed)
        if part == .knob { return dragKnob(grabbedAt: pressed - start.knobStart, along: start, nextEvent) }
        if jumpsToClickedSpot() != down.modifierFlags.contains(.option) {
            scroll(toValue: start.value(centeredAt: pressed))
            return dragKnob(grabbedAt: start.knobLength / 2, along: start, nextEvent)
        }
        return page(toward: part, from: pressed, nextEvent)
    }

    /// Scrolls the scroll view so the knob is at `value` (0 the top or leading end, 1 the other),
    /// as AppKit's own knob drag does: the clip view moves and the scroller follows it.
    func scroll(toValue value: Double) {
        let value = min(max(value, 0), 1)
        guard let scrollView = superview as? NSScrollView, let document = scrollView.documentView,
              scrollView.verticalScroller === self || scrollView.horizontalScroller === self else {
            doubleValue = value
            return
        }
        let clip = scrollView.contentView
        let ends = originEnds(document: document.frame, clip: clip)
        var origin = clip.bounds.origin
        let along = ends.start + CGFloat(value) * (ends.end - ends.start)
        if isHorizontal { origin.x = along } else { origin.y = along }
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        notificationCenter.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    private func fromTop(_ rect: CGRect) -> CGFloat { isFlipped ? rect.minY : bounds.maxY - rect.maxY }

    /// The clip view's origin along the axis with the knob at the start (value 0) and at the end
    /// (value 1), the content insets included. In an unflipped clip the start is the larger y.
    private func originEnds(document: CGRect, clip: NSClipView) -> (start: CGFloat, end: CGFloat) {
        let insets = clip.contentInsets
        if isHorizontal { return (document.minX - insets.left, document.maxX - clip.bounds.width + insets.right) }
        if clip.isFlipped { return (document.minY - insets.top, document.maxY - clip.bounds.height + insets.bottom) }
        return (document.maxY - clip.bounds.height + insets.top, document.minY - insets.bottom)
    }

    /// The knob keeps `grab` (points from its start) under the pointer until the release.
    private func dragKnob(grabbedAt grab: CGFloat, along start: ThinScrollerTrack,
                          _ nextEvent: (NSEvent.EventTypeMask, Date) -> NSEvent?) -> NSEvent? {
        while let event = nextEvent([.leftMouseDragged, .leftMouseUp], .distantFuture) {
            scroll(toValue: start.value(knobStart: axisPosition(of: event) - grab))
            if event.type == .leftMouseUp { return event }
        }
        return nil
    }

    /// Pages toward the press now, and again every ``pageRepeatPeriod`` after ``pageRepeatDelay``
    /// while the button is held and the knob has not reached the pointer.
    private func page(toward part: ThinScrollerTrack.Part, from pressed: CGFloat,
                      _ nextEvent: (NSEvent.EventTypeMask, Date) -> NSEvent?) -> NSEvent? {
        let direction: Double = part == .before ? -1 : 1
        var pointer = pressed
        pageOnce(direction)
        var wait = Self.pageRepeatDelay
        // Each turn blocks in the event queue until the next drag or release, or the repeat's tick;
        // it ends at the release, or when the button is up (another window took the release).
        // wakeup-allow: a press's modal tracking loop, as AppKit's own scroller tracker: it blocks in the window's event queue and ticks only while the button is held.
        repeat {
            if let event = nextEvent([.leftMouseDragged, .leftMouseUp], Date(timeIntervalSinceNow: wait)) {
                if event.type == .leftMouseUp { return event }
                pointer = axisPosition(of: event)
            } else {
                if track.part(at: pointer) == part { pageOnce(direction) }
                wait = Self.pageRepeatPeriod
            }
        } while NSEvent.pressedMouseButtons & 1 != 0
        // The button came up before its release was read: take the release, so it never reaches the content.
        return nextEvent([.leftMouseUp], .distantPast)
    }

    /// One page, as AppKit's page part: the visible length less the scroll view's page overlap.
    private func pageOnce(_ direction: Double) {
        guard let scrollView = superview as? NSScrollView, let document = scrollView.documentView else {
            return scroll(toValue: doubleValue + direction * Double(knobProportion))
        }
        let clip = scrollView.contentView
        let ends = originEnds(document: document.frame, clip: clip)
        let range = abs(ends.end - ends.start)
        guard range > 0 else { return }
        let visible = isHorizontal ? clip.bounds.width : clip.bounds.height
        let overlap = isHorizontal ? scrollView.horizontalPageScroll : scrollView.verticalPageScroll
        scroll(toValue: doubleValue + direction * Double(max(1, visible - overlap) / range))
    }

    private func waitForRelease(_ nextEvent: (NSEvent.EventTypeMask, Date) -> NSEvent?) -> NSEvent? {
        while let event = nextEvent([.leftMouseDragged, .leftMouseUp], .distantFuture) {
            if event.type == .leftMouseUp { return event }
        }
        return nil
    }
}

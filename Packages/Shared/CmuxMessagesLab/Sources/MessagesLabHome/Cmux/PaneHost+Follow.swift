import AppKit

// cmux-classic: the transcript keeps following its newest row across a size change.
//
// A panel opening and closing beside the pane (Chief Settings) resizes the window view in steps
// (an animated frame). Somewhere in those steps AppKit's clip view reported a move of its own,
// which the window view takes as the person's (`userScrolled`), and the pin to the bottom was
// dropped: every later turn landed below the composer. The pin now belongs to the person: only
// their own scrolls (wheel, trackpad, keys, the scroller) choose a place; a move that comes with
// a size change does not. While they chose the bottom, a size change and every engine change keep
// the newest row on the field.

extension HostView {
    /// The store follows its newest row (pinned to the bottom with the newest page loaded).
    var transcriptPinned: Bool {
        guard let s = demo?.store.state else { return true }
        return s.ui.scroll.pinnedToBottom && s.atNewest
    }

    /// Seconds after a size change during which a scroll that is not a live (trackpad, momentum)
    /// scroll is the resize's own, never the person's.
    static let sizeChangeQuiet: CFTimeInterval = 0.4

    /// Whether a scroll is the person's: a live scroll, or a wheel, key or mouse event of theirs
    /// made just now and not inside a size change. Pure, for tests.
    static func isPersonScroll(event: NSEvent.EventType?, eventAge: TimeInterval, liveScrolling: Bool,
                               sinceSizeChange: CFTimeInterval) -> Bool {
        if liveScrolling { return true }
        guard sinceSizeChange > sizeChangeQuiet, let event, eventAge < 0.5 else { return false }
        switch event {
        case .scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged: return true
        default: return false
        }
    }

    /// Whether to put the transcript back on its newest row: the person chose the bottom and the
    /// store dropped the pin (or, after a size change, the offset is off the pin). Pure, for tests.
    static func shouldRepin(following: Bool, pinned: Bool, atNewest: Bool, offsetOffPin: Bool, sizeChanged: Bool) -> Bool {
        guard following, atNewest else { return false }
        return !pinned || (sizeChanged && offsetOffPin)
    }

    /// A scroll reached the window view (`onScrollPosition`): the person's own scroll decides
    /// whether the transcript follows the newest row.
    func noteScrollPosition() {
        let e = NSApp.currentEvent
        let age = e.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? .infinity
        let person = Self.isPersonScroll(event: e?.type, eventAge: age, liveScrolling: scrollView.liveScrolling,
                                         sinceSizeChange: CACurrentMediaTime() - lastSizeChange)
        if person { followsNewest = transcriptPinned }
    }

    /// An explicit place (automation, a jump the host asked for): it decides as the person's scroll does.
    func noteChosenPlace() { followsNewest = transcriptPinned }

    /// After an engine change or a layout: back on the newest row when the person chose it.
    func keepFollowingNewest(sizeChanged: Bool = false) {
        guard let demo else { return }
        let s = demo.store.state
        if s.ui.scroll.pinnedToBottom && s.atNewest { followsNewest = true }
        let off = abs(demo.collection.contentOffset.y - demo.pinnedOffset) > 0.5
        guard Self.shouldRepin(following: followsNewest, pinned: s.ui.scroll.pinnedToBottom, atNewest: s.atNewest,
                               offsetOffPin: off, sizeChanged: sizeChanged) else { return }
        demo.pinToBottom()
        scrollView.syncFromModel()
    }
}

import AppKit

/// Wheel scrolling inside a card (u3320). The card window ignores the mouse (hit tests look
/// through it), so it never gets a wheel event itself: the coordinator hands it the ones whose
/// pointer is on the card.
extension HoverCardPanel {
    /// Scrolls the card's innermost visible scroll view under `screenPoint` by `event`, else its
    /// first one. False when the card has no scroll view (the event is still the card's).
    @discardableResult
    func scrollCard(with event: NSEvent, at screenPoint: CGPoint) -> Bool {
        let scrollViews = Self.scrollViews(in: glass.contentView)
        guard !scrollViews.isEmpty else { return false }
        let under = scrollViews.last { view in
            guard let window = view.window else { return false }
            return window.convertToScreen(view.convert(view.bounds, to: nil)).contains(screenPoint)
        }
        guard let target = under ?? scrollViews.first else { return false }
        Self.scroll(target, by: event)
        return true
    }

    /// Moves `scrollView` by the wheel's delta, clamped to its document. The card window is not
    /// an event target, so `NSScrollView.scrollWheel(with:)` (which may hand the gesture to
    /// responsive scrolling) is not used: the clip view moves at once.
    static func scroll(_ scrollView: NSScrollView, by event: NSEvent) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let lineHeight: CGFloat = event.hasPreciseScrollingDeltas ? 1 : max(scrollView.verticalLineScroll, 10)
        let dy = event.scrollingDeltaY * lineHeight
        let maxY = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + (clip.isFlipped ? -dy : dy), 0), maxY)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The visible scroll views under `root`, a parent before its children.
    static func scrollViews(in root: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        var pending: [NSView] = [root]
        while !pending.isEmpty {
            let view = pending.removeFirst()
            guard !view.isHidden else { continue }
            if let scroll = view as? NSScrollView { out.append(scroll) }
            pending.append(contentsOf: view.subviews)
        }
        return out
    }
}

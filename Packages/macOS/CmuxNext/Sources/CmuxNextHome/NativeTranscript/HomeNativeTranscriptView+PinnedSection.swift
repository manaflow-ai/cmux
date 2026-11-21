public import AppKit

/// A section pinned at the top of the chat, under the header (Chief Home's Needs you): it stays
/// in place while the messages scroll under it. It lies over the transcript, so showing it,
/// hiding it or a change of its height moves no message (no layout shift); the host decides what
/// it shows and when (nil: none).
extension HomeNativeTranscriptView {
    /// The pinned section shown now (tests and `debug.home`).
    public var pinnedSection: NSView? { pinned?.view }
    /// The Set Up cmux card's view shown now: its buttons keep their keys (Home's typing redirect skips it).
    public var setupCardView: NSView? { setupCard?.view }

    /// Shows `view` pinned under the header, measured now (its fitting height); nil removes it.
    public func setPinnedSection(_ view: NSView?) {
        guard view !== pinned?.view else { return pinnedSectionDidResize() }
        pinned?.view.removeFromSuperview()
        pinned = nil
        transcript.rowsTopClearance = 0
        if let view {
            // Over the transcript and the first-run panel, under the notice above the field.
            addSubview(view, positioned: .below, relativeTo: noticeLabel)
            pinned = (view, nil)
            layoutPinnedSection()
        }
        needsLayout = true
    }

    /// The pinned section's content changed height (a request came or went): it is measured again
    /// in the next layout pass, never inside the content's own update.
    public func pinnedSectionDidResize() {
        guard let view = pinned?.view else { return }
        pinned = (view, nil)
        needsLayout = true
    }

    /// Shows `view` (Home's Set Up cmux card, a page sized to its card) under the pinned section, `height` points
    /// tall; nil removes it. Like the pinned section it lies over the transcript, so no message moves.
    public func setSetupCard(_ view: NSView?, height: CGFloat) {
        if view !== setupCard?.view {
            setupCard?.view.removeFromSuperview()
            if let view { addSubview(view, positioned: .below, relativeTo: noticeLabel) }
        }
        setupCard = view.map { ($0, height) }
        needsLayout = true
    }

    /// The room the pinned section and the setup card take under the header (the first-run panel starts below them).
    var pinnedSectionClearance: CGFloat {
        let bottoms = [pinned.flatMap { ($0.height ?? 0) > 0 ? $0.view.frame.maxY : nil },
                       setupCard.flatMap { $0.height > 0 ? $0.view.frame.maxY : nil }].compactMap { $0 }
        guard let bottom = bottoms.max() else { return 0 }
        return bottom - transcript.headerHeight + 8
    }

    /// Under the header, inset from the sides like the field, no wider than a reading column; never
    /// over the message box. The setup card goes under the pinned section.
    func layoutPinnedSection() {
        let inset: CGFloat = 12
        let width = min(max(0, bounds.width - 2 * inset), Self.pinnedSectionMaxWidth)
        let x = ((bounds.width - width) / 2).rounded()
        var top = transcript.headerHeight + 4
        var bottom: CGFloat?
        // A sized setup card keeps a usable height under a tall pinned section (many Needs you rows), which
        // gives up that room and clips; the card's page scrolls in what it gets.
        let cardFloor = setupCard.map { min($0.height, Self.setupCardMinHeight) } ?? 0
        if let pinned {
            let view = pinned.view
            let height = pinned.height ?? ceil(view.fittingSize.height)
            if pinned.height == nil { self.pinned = (view, height) }
            let shown = min(height, max(0, transcript.fieldTop - top - 8 - (cardFloor > 0 ? cardFloor + 8 : 0)))
            let frame = CGRect(x: x, y: top, width: width, height: shown)
            if view.frame != frame { view.frame = frame }
            if shown > 0 { bottom = frame.maxY; top = frame.maxY + 8 }
        }
        if let card = setupCard {
            // Before its first size the page stays in the window at 1 pt (never hidden): a hidden web view
            // stops measuring, and the card would never report the height that shows it.
            // Taller than the room above the message box, the slot stops there and the page scrolls.
            let shown = min(card.height, max(0, transcript.fieldTop - top - 8))
            let frame = CGRect(x: x, y: top, width: width, height: max(shown, 1))
            if card.view.frame != frame { card.view.frame = frame }
            if shown > 0 { bottom = frame.maxY }
        }
        // The oldest message scrolls clear of the cards (only the top of the scroll range moves).
        transcript.rowsTopClearance = bottom.map { max(0, $0 - transcript.headerHeight + 4) } ?? 0
    }

    /// The pinned section's widest.
    static let pinnedSectionMaxWidth: CGFloat = 640
    /// The least of a sized setup card's height a pinned section leaves it: its title and a row, the rest scrolls.
    static let setupCardMinHeight: CGFloat = 120
}

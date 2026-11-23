import AppKit

// The first card's one-time work, done ahead (goal sidebar-hover-instant; Leo 2026-11-01: "i need these hover
// previews to appear a hell of a lot faster than they do now").
extension HoverCardCoordinator {
    /// Makes the card window (its window-server window too) and each registered source's card body
    /// (``HoverCardSource/hoverCardWarmBody()``), lays the card out and draws it once off screen, with nothing shown.
    /// The first card after launch built all of it on its show and took about 50 ms more than every later card
    /// (hover-instant bench at 9264e88, last move to shown: 105 ms on the first sample, 50-74 ms after); with this,
    /// the first show reuses them. The app calls it once, at its first idle moment after launch; a card pending or
    /// shown, or a card window already made, makes it do nothing.
    public func warm() {
        guard panel == nil, machine.activeTarget == nil, owned == nil else { return }
        let warmed = HoverCardPanel(deferred: false)
        panel = warmed
        // One body: the card window holds one, so warming every window's sidebar would build and draw bodies only to drop them.
        for entry in sources.values {
            guard let source = entry.source, let parent = source.hoverCardWindow, parent.isVisible,
                  let body = source.hoverCardWarmBody() else { continue }
            warmed.warm(body, parent: parent)
            return
        }
    }
}

public import AppKit

extension LayoutRootView {
    /// A pane-navigation key: Focus Pane Left/Right/Up/Down (`direction`), Next and Previous Pane (`cycle`).
    public enum PaneMove: Sendable, Equatable {
        case direction(LayoutDirection)
        case cycle(offset: Int)
    }

    /// The pane `move` lands on from `pane` on its screen, active or not: by displayed frames and `recency` (the
    /// most recently focused of several adjacent panes, and of a strip column; focus.md section 4a) for a direction,
    /// in visual order for a cycle. `layout` stands in for the layout the screen shows, at the size it has now, with
    /// nothing laid out: a zoomed screen's unzoomed layout under Ghostty's `split-preserve-zoom = navigation`
    /// (cmux#47785). Nil when no pane lies there (a cycle on a one-pane screen).
    public func paneTarget(of pane: PaneID, _ move: PaneMove, recency: [PaneID] = [], showing layout: ScreenLayout? = nil) -> PaneID? {
        guard let screen = model.screen(containing: pane) else { return nil }
        switch move {
        case .direction(let direction):
            guard let view = screenViews[screen.id] else { return nil } // a deferred screen has no frames yet
            // One logical line: docked columns before and after the strip. The frames of `pane`'s own screen,
            // active or not: what opens beside a chat on a screen the person left reads that screen (#28044).
            let frames = layout.map(view.navigationFrames(showing:)) ?? view.navigationFrames
            return FocusNavigation.neighbor(of: pane, direction: direction, frames: frames, recency: recency,
                                            columns: (layout ?? screen.layout).columns.map(\.root.panes))
        case .cycle(let offset):
            let order = (layout ?? screen.layout).visualPanes
            guard order.count > 1, let index = order.firstIndex(of: pane) else { return nil }
            return order[(index + offset + order.count) % order.count]
        }
    }
}

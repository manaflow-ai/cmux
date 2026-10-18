/// How near a pane is to the viewport of the active screen.
public nonisolated enum PanePresence: Hashable, Sendable {
    /// Its frame intersects the viewport: render.
    case visible
    /// Off screen but within one viewport width of it (architecture.md 4):
    /// keep content alive, paused, so a scroll back shows it at once.
    case keepAlive
    /// Farther away or on an inactive screen: content may be released.
    case hidden

    init(_ pane: PaneID, visible: Set<PaneID>, keepAlive: Set<PaneID>) {
        self = visible.contains(pane) ? .visible : keepAlive.contains(pane) ? .keepAlive : .hidden
    }

    /// Ordering for change delivery: releases before acquisitions.
    var rank: Int {
        switch self {
        case .hidden: 0
        case .keepAlive: 1
        case .visible: 2
        }
    }
}

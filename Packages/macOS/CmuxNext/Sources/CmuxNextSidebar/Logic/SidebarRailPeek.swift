/// When the rail's full sidebar is open (`sidebar.style` = rail,
/// plans/cmux-next/minimal-sidebar.md). A pure reducer: the container feeds
/// it pointer and timer events and runs the effect it returns.
///
/// - The pointer resting on the rail for `dwell` opens it, so a pass to the
///   window edge (to resize, to reach the Dock) does not.
/// - Leaving the open sidebar closes it after `grace`, unless the person is
///   busy there then (a mouse button down: a drag; a menu tracking; a
///   rename field), which waits another grace.
/// - `reveal` opens it at once (a rename, the filter, a reveal from the
///   palette); it closes like a hover once the pointer has left.
public nonisolated struct SidebarRailPeek: Hashable, Sendable {
    public enum Event: Hashable, Sendable {
        case pointerEnteredRail
        /// The pointer is over the open sidebar.
        case pointerEnteredSidebar
        case pointerExited
        case dwellElapsed
        /// - Parameter busy: The person is mid-gesture in the sidebar.
        case graceElapsed(busy: Bool)
        case reveal
        /// Collapse now (the style changed, the sidebar was hidden).
        case reset
    }

    public enum Effect: Hashable, Sendable {
        case none
        case startDwell
        case startGrace
        case cancelTimers
    }

    public private(set) var isOpen = false
    public private(set) var pointerInside = false
    private var arming = false

    public init() {}

    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .pointerEnteredRail, .pointerEnteredSidebar:
            pointerInside = true
            if isOpen { return .cancelTimers }
            guard !arming else { return .none }
            arming = true
            return .startDwell
        case .pointerExited:
            pointerInside = false
            if arming {
                arming = false
                return .cancelTimers
            }
            return isOpen ? .startGrace : .none
        case .dwellElapsed:
            guard arming else { return .none }
            arming = false
            isOpen = pointerInside
            return .none
        case let .graceElapsed(busy):
            guard isOpen, !pointerInside else { return .none }
            if busy { return .startGrace }
            isOpen = false
            return .none
        case .reveal:
            arming = false
            isOpen = true
            return pointerInside ? .cancelTimers : .startGrace
        case .reset:
            (isOpen, arming, pointerInside) = (false, false, false)
            return .cancelTimers
        }
    }
}

/// Where the collapsed sidebar's hover-reveal currently sits.
///
/// Peek exists so a collapsed sidebar is still reachable without a keystroke:
/// the pointer rests at the window's leading edge and the workspace list floats
/// in over the content, the way Arc and Aside reveal a hidden rail.
public enum SidebarPeekPhase: String, Sendable, Hashable, CaseIterable {
    /// Collapsed and idle. Nothing is drawn and no timer is running.
    case idle
    /// The pointer is in the edge zone and the dwell timer is running.
    ///
    /// Dwell is what keeps peek from being a nuisance. Without it, every
    /// pointer trip across the leading edge on the way to a terminal flashes
    /// the sidebar open.
    case arming
    /// The panel is presented.
    case peeking
    /// The panel is presented and the grace timer is running toward dismissal.
    ///
    /// Grace absorbs the gap between leaving the edge strip and entering the
    /// panel, and it forgives a pointer that wobbles off the panel's edge.
    case dismissing

    /// Whether the floating panel is on screen in this phase.
    public var presentsPanel: Bool {
        switch self {
        case .idle, .arming:
            return false
        case .peeking, .dismissing:
            return true
        }
    }
}

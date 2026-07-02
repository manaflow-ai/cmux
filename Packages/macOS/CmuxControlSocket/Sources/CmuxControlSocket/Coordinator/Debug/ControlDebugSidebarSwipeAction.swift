#if DEBUG
/// Synthetic sidebar-row swipe actions accepted by
/// `debug.sidebar.simulate_swipe`.
public enum ControlDebugSidebarSwipeAction: String, Sendable, Equatable, CaseIterable {
    /// Reveal the leading swipe action and leave it visible.
    case revealLeading = "reveal-leading"
    /// Reveal the trailing swipe action and leave it visible.
    case revealTrailing = "reveal-trailing"
    /// Swipe past the leading commit threshold and release.
    case commitLeading = "commit-leading"
    /// Swipe past the trailing commit threshold and release.
    case commitTrailing = "commit-trailing"
    /// Release any currently revealed sidebar row.
    case release
}
#endif

/// A part of the window that comes in on its own at launch, as soon as its
/// own data is ready (`LaunchReveal`).
public nonisolated enum LaunchRegion: String, Sendable, CaseIterable {
    /// The sidebar: its first workspace row, or a loaded tree with none.
    case sidebar
    /// The panes' tab strips: the first non-empty strip.
    case tabs
    /// Pane content: the first terminal frame.
    case pane
    /// Home: its conversation's first page (header, first-run actions, message box).
    case home

    /// Made after the launch window (Home: over several daemon replies), so its wait runs from
    /// its own first hold; the launch deadline, armed by the window's holds, leaves it held.
    public var hasOwnDeadline: Bool { self == .home }
}

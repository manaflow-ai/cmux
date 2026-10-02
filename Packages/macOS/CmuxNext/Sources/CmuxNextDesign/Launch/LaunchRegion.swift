/// A part of the window that comes in on its own at launch, as soon as its
/// own data is ready (`LaunchReveal`).
public nonisolated enum LaunchRegion: String, Sendable, CaseIterable {
    /// The sidebar: its first workspace row, or a loaded tree with none.
    case sidebar
    /// The panes' tab strips: the first non-empty strip.
    case tabs
    /// Pane content: the first terminal frame.
    case pane
}

/// A widget's size, as Apple's widget families (`cmux.widget/1` `options.sizes`). The tile counts
/// are the daemon's (`cmux-tui-core` `apps/widgets.rs`), the same unit on New Tab and in the sidebar:
/// small is one square tile, medium two tiles wide, large two by two. The sidebar takes small and
/// medium only (``sidebar``).
public nonisolated enum AppWidgetSize: String, Sendable, Hashable, CaseIterable {
    case small
    case medium
    case large

    /// The sizes a sidebar tile can have, smallest first.
    public static let sidebar: [AppWidgetSize] = [.small, .medium]

    /// Its tiles on the grid: (columns, rows).
    public var tiles: (columns: Int, rows: Int) {
        switch self {
        case .small: (1, 1)
        case .medium: (2, 1)
        case .large: (2, 2)
        }
    }
}

import CoreGraphics

/// Where `SidebarLayout.make` puts the session tree's chat history (`SidebarChatHistoryState`):
/// Pinned right above the first computer's workspaces, Earlier right under the last computer's.
/// Each block is a gap in the rows that the list's history views fill, so no row hit-tests there.
nonisolated struct SidebarChatHistoryPlacement {
    private let pinnedHeight: CGFloat
    private let earlierHeight: CGFloat
    private let spacing: CGFloat
    private(set) var pinnedY: CGFloat?
    private(set) var earlierY: CGFloat?

    /// Nil `history` (the tree off, or a filter) places nothing.
    init(_ history: SidebarChatHistoryState?, metrics m: SidebarLayoutMetrics) {
        pinnedHeight = history?.pinnedHeight(m) ?? 0
        earlierHeight = history?.earlierHeight(m) ?? 0
        spacing = m.sectionSpacing
    }

    /// Pinned at `y`, once. Its rows end with the row spacing, so the first workspace row follows its last
    /// pinned chat as the next row does any other (no section gap after the pins, Leo 2026-10-21).
    mutating func placePinned(_ y: inout CGFloat) {
        guard pinnedY == nil, pinnedHeight > 0 else { return }
        pinnedY = y
        y += pinnedHeight
    }

    /// Earlier a section's spacing under `y`, once; Pinned first when no computer took it.
    mutating func placeEarlier(_ y: inout CGFloat) {
        placePinned(&y)
        guard earlierY == nil, earlierHeight > 0 else { return }
        y += spacing
        earlierY = y
        y += earlierHeight
    }
}

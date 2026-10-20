public import Foundation

/// One navigable focus-history menu row: the underlying entry plus the
/// resolved display titles captured at snapshot time.
public struct FocusHistoryMenuItem: Equatable, Sendable {
    /// The entry's index in the history stack when the snapshot was taken.
    public let historyIndex: Int
    /// The underlying history entry.
    public let entry: FocusHistoryEntry
    /// The workspace's trimmed display title.
    public let workspaceTitle: String
    /// The panel's trimmed display title, when one resolved.
    public let panelTitle: String?
    /// Whether the item is older or newer than the current position.
    public let position: FocusHistoryMenuPosition
    /// When the focus landed.
    public let focusedAt: Date
    /// Whether selecting the item can navigate.
    public let isNavigable: Bool

    /// Creates a menu item.
    public init(
        historyIndex: Int,
        entry: FocusHistoryEntry,
        workspaceTitle: String,
        panelTitle: String?,
        position: FocusHistoryMenuPosition,
        focusedAt: Date,
        isNavigable: Bool
    ) {
        self.historyIndex = historyIndex
        self.entry = entry
        self.workspaceTitle = workspaceTitle
        self.panelTitle = panelTitle
        self.position = position
        self.focusedAt = focusedAt
        self.isNavigable = isNavigable
    }
}

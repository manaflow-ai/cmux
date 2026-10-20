public import Foundation

/// Value snapshot of one tab in a pane's chrome strip.
public struct CanvasTabChrome: Equatable, Sendable, Identifiable {
    /// The panel this tab shows.
    public let id: UUID
    public var title: String
    public var iconSystemName: String?

    public init(id: UUID, title: String, iconSystemName: String?) {
        self.id = id
        self.title = title
        self.iconSystemName = iconSystemName
    }
}

/// Value snapshot of a pane's chrome strip: its tabs, selection, focus ring,
/// and pre-localized action labels. Localized text crosses this seam
/// pre-resolved so the package owns no string catalogs.
public struct CanvasPaneChrome: Equatable, Sendable {
    /// Tabs left to right. Never empty.
    public var tabs: [CanvasTabChrome]
    /// The selected tab's panel id.
    public var selectedTabId: UUID?
    public var isFocused: Bool
    /// Localized label for the close action (help tag + accessibility).
    public var closeActionLabel: String

    public init(
        tabs: [CanvasTabChrome],
        selectedTabId: UUID?,
        isFocused: Bool,
        closeActionLabel: String
    ) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.isFocused = isFocused
        self.closeActionLabel = closeActionLabel
    }
}

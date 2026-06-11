public import Foundation

/// A Sendable snapshot of one browser tab for `browser.tab.list`, in workspace
/// panel order (the coordinator derives the wire `index` from array position).
public struct ControlBrowserTabSummary: Sendable, Equatable {
    /// The browser surface id.
    public let surfaceID: UUID
    /// The panel's display title.
    public let title: String
    /// The panel's current URL (empty string when none, as legacy).
    public let url: String
    /// Whether this surface is the workspace's focused panel.
    public let isFocused: Bool
    /// The containing pane id, if resolved.
    public let paneID: UUID?

    /// Creates a tab summary.
    ///
    /// - Parameters:
    ///   - surfaceID: The browser surface id.
    ///   - title: The panel's display title.
    ///   - url: The panel's current URL.
    ///   - isFocused: Whether this surface is focused.
    ///   - paneID: The containing pane id, if resolved.
    public init(surfaceID: UUID, title: String, url: String, isFocused: Bool, paneID: UUID?) {
        self.surfaceID = surfaceID
        self.title = title
        self.url = url
        self.isFocused = isFocused
        self.paneID = paneID
    }
}

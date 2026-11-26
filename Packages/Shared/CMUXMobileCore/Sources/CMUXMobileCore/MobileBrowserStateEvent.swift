import Foundation

/// Payload pushed on the `browser.state` topic.
public struct MobileBrowserStateEvent: Codable, Equatable, Sendable {
    /// Browser panel UUID string.
    public let panelID: String
    /// Current page URL, when available.
    public let url: String?
    /// Current page title, when available.
    public let title: String?
    /// Whether backward navigation is available.
    public let canGoBack: Bool
    /// Whether forward navigation is available.
    public let canGoForward: Bool
    /// Whether the page is loading.
    public let isLoading: Bool
    /// Estimated loading progress in the closed range `0...1`.
    public let progress: Double
    /// Whether the page's focused element accepts text input.
    public let editableFocused: Bool

    /// Creates a browser state event.
    public init(
        panelID: String,
        url: String?,
        title: String?,
        canGoBack: Bool,
        canGoForward: Bool,
        isLoading: Bool,
        progress: Double,
        editableFocused: Bool
    ) {
        self.panelID = panelID
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.progress = min(max(progress, 0), 1)
        self.editableFocused = editableFocused
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case url
        case title
        case canGoBack = "can_go_back"
        case canGoForward = "can_go_forward"
        case isLoading = "is_loading"
        case progress
        case editableFocused = "editable_focused"
    }
}

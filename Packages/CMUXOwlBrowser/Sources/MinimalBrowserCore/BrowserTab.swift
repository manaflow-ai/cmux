import Foundation

public struct BrowserTab: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var committedURL: String
    public var history: [String]
    public var historyIndex: Int
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        title: String = URLDisplay.newTabTitle,
        committedURL: String = "about:blank",
        history: [String] = ["about:blank"],
        historyIndex: Int = 0,
        isLoading: Bool = false,
        canGoBack: Bool? = nil,
        canGoForward: Bool? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.committedURL = committedURL
        self.history = history
        self.historyIndex = historyIndex
        self.isLoading = isLoading
        self.canGoBack = canGoBack ?? (historyIndex > 0)
        self.canGoForward = canGoForward ?? (historyIndex + 1 < history.count)
        self.isPinned = isPinned
    }

    public var displayTitle: String {
        if title.isEmpty {
            return URLDisplay.title(for: committedURL)
        }
        return title
    }
}

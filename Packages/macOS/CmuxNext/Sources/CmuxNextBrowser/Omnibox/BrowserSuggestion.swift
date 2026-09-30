public import Foundation

/// One row in the address bar dropdown.
public nonisolated struct BrowserSuggestion: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Load the typed URL.
        case navigate
        /// Search for the typed or suggested query.
        case search
        /// A page from history.
        case history
        /// An extension's suggestion in a keyword session (`chrome.omnibox`).
        case keyword
    }

    public var kind: Kind
    /// Main line: page title or query.
    public var title: String
    /// Second line: display URL, or empty.
    public var detail: String
    public var url: URL
    /// Higher ranks first. Providers use `0...1000`.
    public var score: Double
    /// Keyword rows: the text sent to the extension and put in the field.
    public var content: String?

    public var id: String { "\(kind)|\(url.absoluteString)" }

    public init(kind: Kind, title: String, detail: String, url: URL, score: Double) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
        self.score = score
    }
}

/// Source of suggestion rows. Providers must be cheap for local data; remote
/// providers should honor task cancellation, because every keystroke cancels
/// the previous query.
public protocol BrowserSuggestionProvider: AnyObject {
    func suggestions(for text: String) async -> [BrowserSuggestion]
}

/// A provider whose rows the user can delete (Shift-Delete).
public protocol BrowserSuggestionDeleting: AnyObject {
    func deleteSuggestion(_ url: URL)
}

// MARK: - History

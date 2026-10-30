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
        /// A bookmarked page (star icon; plans/cmux-next/bookmarks.md).
        case bookmark
        /// An extension's suggestion in a keyword session (`chrome.omnibox`).
        case keyword
        /// An open tab of the same profile: Enter reveals it ("Switch to Tab").
        case switchToTab
        /// A calculator answer: Enter copies it (`content`), never navigates.
        case answer
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
    /// Inline autocomplete may complete the typed text to this row. The
    /// suggestion pipeline allows it only on its top local row
    /// (`OmniboxPhaseA`); rows from other providers keep the default.
    public var inlineCompletable = true
    /// Switch to Tab rows: the tab to reveal.
    public var tabKey: String?

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

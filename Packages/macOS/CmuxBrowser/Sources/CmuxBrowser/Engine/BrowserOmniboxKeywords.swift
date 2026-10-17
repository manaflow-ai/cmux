public import Foundation

/// An extension's omnibox keyword (`chrome.omnibox`, manifest
/// `omnibox.keyword`). Typing the keyword and a space in a Chromium panel's
/// address bar starts a keyword session: the extension gets every change of
/// the text after the keyword and answers with suggestions, and Return
/// hands that text to the extension instead of loading it.
///
/// Reference: cmux Next `CmuxNextBrowser/Omnibox/OmnibarKeyword.swift`.
public struct BrowserOmniboxKeyword: Hashable, Sendable {
    public var extensionID: String
    public var keyword: String
    /// The extension's name.
    public var name: String
    /// `omnibox.setDefaultSuggestion`, shown for the typed text (`%s`).
    public var defaultDescription: String?

    public init(extensionID: String, keyword: String, name: String, defaultDescription: String? = nil) {
        self.extensionID = extensionID
        self.keyword = keyword
        self.name = name
        self.defaultDescription = defaultDescription
    }

    /// The keyword `text` starts, followed by a space, and the text after
    /// that space. Keywords compare without case; leading spaces of `text`
    /// do not count.
    public static func match(_ text: String, in keywords: [BrowserOmniboxKeyword]) -> (keyword: BrowserOmniboxKeyword, rest: String)? {
        let text = String(text.drop(while: { $0 == " " }))
        for keyword in keywords where !keyword.keyword.isEmpty {
            let prefix = keyword.keyword + " "
            guard text.count >= prefix.count,
                  text.prefix(prefix.count).lowercased() == prefix.lowercased() else { continue }
            return (keyword, String(text.dropFirst(prefix.count)))
        }
        return nil
    }

    /// The row for the typed text itself: the extension's default
    /// description with `%s` replaced, else "name: text".
    public func defaultSuggestion(for text: String) -> BrowserOmniboxKeywordSuggestion {
        let description = defaultDescription.map { $0.replacingOccurrences(of: "%s", with: text) } ?? "\(name): \(text)"
        return BrowserOmniboxKeywordSuggestion(extensionID: extensionID, content: text, description: description)
    }

    /// The session's rows: the default row for `text` first (shown before
    /// the extension answers), then the extension's rows in order, without
    /// repeated contents.
    public func rows(text: String, suggestions: [BrowserOmniboxKeywordSuggestion]) -> [BrowserOmniboxKeywordSuggestion] {
        var rows: [BrowserOmniboxKeywordSuggestion] = text.isEmpty ? [] : [defaultSuggestion(for: text)]
        for suggestion in suggestions where !suggestion.content.isEmpty
            && !rows.contains(where: { $0.content == suggestion.content }) {
            rows.append(suggestion)
        }
        return rows
    }
}

/// A row an extension suggests for its keyword session: `content` goes to
/// the extension when chosen; `description` is what the row shows.
public struct BrowserOmniboxKeywordSuggestion: Hashable, Sendable {
    public var extensionID: String
    public var content: String
    public var description: String

    public init(extensionID: String, content: String, description: String) {
        self.extensionID = extensionID
        self.content = content
        self.description = description.isEmpty ? content : description
    }
}

/// Where the extension shows what Return chose (`onInputEntered`).
public enum BrowserOmniboxKeywordDisposition: Sendable {
    case currentTab
    case newForegroundTab
    case newBackgroundTab
}

/// Which keyword session an address bar has open. Feed it the session the
/// current text matches; it answers the session events to send.
public struct BrowserOmniboxKeywordSessionState: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// `onInputStarted` of the extension.
        case started(String)
        /// `onInputCancelled` of the extension.
        case cancelled(String)
    }

    /// The extension whose session is open.
    public private(set) var activeExtensionID: String?

    public init() {}

    /// The text now matches `extensionID`'s keyword (nil: no keyword).
    public mutating func update(_ extensionID: String?) -> [Change] {
        guard extensionID != activeExtensionID else { return [] }
        var changes: [Change] = []
        if let active = activeExtensionID { changes.append(.cancelled(active)) }
        if let extensionID { changes.append(.started(extensionID)) }
        activeExtensionID = extensionID
        return changes
    }

    /// Return handed the text to the extension: the session is over
    /// without a cancel.
    public mutating func entered() {
        activeExtensionID = nil
    }
}

/// A Chromium page whose profile's extensions can take address bar input
/// (`chrome.omnibox`). WebKit pages never conform.
@MainActor
public protocol BrowserPageOmniboxKeywordProviding: AnyObject {
    /// Keywords of the enabled extensions of the page's profile.
    func omniboxKeywords() -> [BrowserOmniboxKeyword]
    /// A session started (`onInputStarted`).
    func omniboxKeywordStarted(_ extensionID: String)
    /// The session's text changed (`onInputChanged`); the extension's rows,
    /// empty when it does not listen or does not answer in time.
    func omniboxKeywordSuggestions(_ extensionID: String, text: String) async -> [BrowserOmniboxKeywordSuggestion]
    /// Return (`onInputEntered`).
    func omniboxKeywordEntered(_ extensionID: String, text: String, disposition: BrowserOmniboxKeywordDisposition)
    /// The session ended without Return (`onInputCancelled`).
    func omniboxKeywordEnded(_ extensionID: String)
}

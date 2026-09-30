public import Foundation

/// An extension's omnibox keyword (`chrome.omnibox`, manifest
/// `omnibox.keyword`). Typing the keyword and a space (or Tab after the
/// keyword) in the omnibar starts a keyword session: the field then holds
/// only the text after the keyword, the extension gets every change and
/// answers with suggestions, and Enter hands the text to the extension
/// (Chrome's keyword mode).
public nonisolated struct OmnibarKeyword: Hashable, Sendable {
    public var extensionID: String
    public var keyword: String
    /// The extension's name, shown in the chip.
    public var name: String
    /// `omnibox.setDefaultSuggestion`, shown for the typed text.
    public var defaultDescription: String?

    public init(extensionID: String, keyword: String, name: String, defaultDescription: String? = nil) {
        self.extensionID = extensionID
        self.keyword = keyword
        self.name = name
        self.defaultDescription = defaultDescription
    }

    /// The keyword `text` starts, followed by a space: the session's
    /// keyword and the text after that space. Keywords compare without case.
    static func match(_ text: String, in keywords: [OmnibarKeyword]) -> (keyword: OmnibarKeyword, rest: String)? {
        for keyword in keywords where !keyword.keyword.isEmpty {
            let prefix = keyword.keyword + " "
            guard text.count >= prefix.count,
                  text.prefix(prefix.count).lowercased() == prefix.lowercased() else { continue }
            return (keyword, String(text.dropFirst(prefix.count)))
        }
        return nil
    }

    /// The keyword `text` is exactly (Tab starts its session).
    static func exact(_ text: String, in keywords: [OmnibarKeyword]) -> OmnibarKeyword? {
        keywords.first { !$0.keyword.isEmpty && $0.keyword.lowercased() == text.lowercased() }
    }

    /// A suggestion row of the extension: `content` goes into the field and
    /// to the extension; `description` is what the row shows.
    public static func suggestionRow(extensionID: String, content: String, description: String, rank: Int) -> BrowserSuggestion {
        var components = URLComponents()
        components.scheme = "cmux-omnibox"
        components.host = extensionID.isEmpty ? "extension" : extensionID
        components.path = "/" + content
        let url = components.url ?? URL(string: "cmux-omnibox://extension/")!
        var row = BrowserSuggestion(kind: .keyword, title: description.isEmpty ? content : description,
                                    detail: description.isEmpty || description == content ? "" : content,
                                    url: url, score: Double(1000 - rank))
        row.content = content
        return row
    }
}

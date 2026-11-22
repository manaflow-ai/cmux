import Foundation

// Design mode (plans/cmux-next/design-mode-DESIGN.md): a pick's name, the comment bubble's words
// and the notices the browser shows when a pick cannot reach a chat.
extension Strings {
    /// A pick's name, for its chat chip and its Home file: `<number> · <comment>`, or with no comment
    /// `<number> · <tag> · <host>`. The number is its pin's on the page.
    nonisolated static func designModeCardName(number: Int, comment: String, tag: String, host: String) -> String {
        if !comment.isEmpty {
            let short = comment.count > 80 ? String(comment.prefix(79)) + "…" : comment
            let flat = short.replacingOccurrences(of: "\n", with: " ")
            return String(localized: "browser.designMode.pickName", defaultValue: "\(number) · \(flat)", bundle: .localizedModule)
        }
        return host.isEmpty
            ? String(localized: "browser.designMode.pickNameElementNoHost", defaultValue: "\(number) · \(tag)", bundle: .localizedModule)
            : String(localized: "browser.designMode.pickNameElement", defaultValue: "\(number) · \(tag) · \(host)", bundle: .localizedModule)
    }
}

/// Design mode's user-facing notices, for the App layer that routes highlights.
public nonisolated struct BrowserDesignModeStrings: Sendable {
    public init() {}

    /// The browser's notice when no agent chat in its workspace can take a highlight.
    public var noAgentChat: String {
        String(localized: "browser.designMode.noAgentChat",
               defaultValue: "Open an agent chat in this workspace to send design highlights to it.", bundle: .localizedModule)
    }

    /// The comment bubble's placeholder, under a picked element.
    public var commentPlaceholder: String {
        String(localized: "browser.designMode.commentPlaceholder", defaultValue: "Add a comment", bundle: .localizedModule)
    }

    /// The bubble's hint for a new pick: Return adds it.
    public var commentAdd: String {
        String(localized: "browser.designMode.commentAdd", defaultValue: "Return to add", bundle: .localizedModule)
    }

    /// The bubble's hint for an added pick being edited: Return saves it.
    public var commentSave: String {
        String(localized: "browser.designMode.commentSave", defaultValue: "Return to save", bundle: .localizedModule)
    }

    /// The browser's notice when the page refused design mode (a script error).
    public var couldNotStart: String {
        String(localized: "browser.designMode.couldNotStart", defaultValue: "Design mode could not start on this page.", bundle: .localizedModule)
    }
}

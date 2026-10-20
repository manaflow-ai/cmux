import Foundation

// Design mode (plans/cmux-next/design-mode-DESIGN.md): the composer card's name and the notices
// the browser shows when a highlight cannot reach a chat.
extension Strings {
    /// `Design: <tag> · <host>`, the chip an agent chat's composer shows for one highlight.
    nonisolated static func designModeCardName(tag: String, host: String) -> String {
        host.isEmpty
            ? String(localized: "browser.designMode.cardNameNoHost", defaultValue: "Design: \(tag)", bundle: .module)
            : String(localized: "browser.designMode.cardName", defaultValue: "Design: \(tag) · \(host)", bundle: .module)
    }
}

/// Design mode's user-facing notices, for the App layer that routes highlights.
public nonisolated struct BrowserDesignModeStrings: Sendable {
    public init() {}

    /// The browser's notice when no agent chat in its workspace can take a highlight.
    public var noAgentChat: String {
        String(localized: "browser.designMode.noAgentChat",
               defaultValue: "Open an agent chat in this workspace to send design highlights to it.", bundle: .module)
    }

    /// The browser's notice when the page refused design mode (a script error).
    public var couldNotStart: String {
        String(localized: "browser.designMode.couldNotStart", defaultValue: "Design mode could not start on this page.", bundle: .module)
    }
}

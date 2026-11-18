import Foundation

// Search Tabs text. Keys live in the palette's Localizable.xcstrings.
nonisolated extension PaletteStrings {
    static var tabSearchTitle: String { String(localized: "palette.tabSearch.title", defaultValue: "Search Tabs", bundle: .l10n) }
    static var tabSearchPlaceholder: String {
        String(localized: "palette.tabSearch.placeholder", defaultValue: "Search tabs by title, URL, folder or process…", bundle: .l10n)
    }
    static var tabSearchOpenSection: String { String(localized: "palette.tabSearch.section.open", defaultValue: "Open Tabs", bundle: .l10n) }
    static var tabSearchClosedSection: String {
        String(localized: "palette.tabSearch.section.closed", defaultValue: "Recently Closed", bundle: .l10n)
    }
    static var tabSearchReopen: String { String(localized: "palette.tabSearch.reopen", defaultValue: "Reopen Tab", bundle: .l10n) }
    static var tabSearchForget: String { String(localized: "palette.tabSearch.forget", defaultValue: "Remove from List", bundle: .l10n) }
    static var tabSearchUntitled: String { String(localized: "palette.tabSearch.untitled", defaultValue: "Untitled", bundle: .l10n) }
    static var tabSearchKindTerminal: String { String(localized: "palette.tabSearch.kind.terminal", defaultValue: "terminal", bundle: .l10n) }
    static var tabSearchKindBrowser: String { String(localized: "palette.tabSearch.kind.browser", defaultValue: "browser", bundle: .l10n) }
}

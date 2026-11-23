import Foundation

// Search Tabs text. Keys live in the palette's Localizable.xcstrings.
nonisolated extension PaletteStrings {
    static var tabSearchTitle: String { String(localized: "palette.tabSearch.title", defaultValue: "Search Tabs", bundle: .localizedModule) }
    static var tabSearchPlaceholder: String {
        String(localized: "palette.tabSearch.placeholder", defaultValue: "Search tabs by title, URL, folder or process…", bundle: .localizedModule)
    }
    static var tabSearchOpenSection: String { String(localized: "palette.tabSearch.section.open", defaultValue: "Open Tabs", bundle: .localizedModule) }
    static var tabSearchClosedSection: String {
        String(localized: "palette.tabSearch.section.closed", defaultValue: "Recently Closed", bundle: .localizedModule)
    }
    static var tabSearchReopen: String { String(localized: "palette.tabSearch.reopen", defaultValue: "Reopen Tab", bundle: .localizedModule) }
    static var tabSearchForget: String { String(localized: "palette.tabSearch.forget", defaultValue: "Remove from List", bundle: .localizedModule) }
    static var tabSearchUntitled: String { String(localized: "palette.tabSearch.untitled", defaultValue: "Untitled", bundle: .localizedModule) }
    static var tabSearchKindTerminal: String { String(localized: "palette.tabSearch.kind.terminal", defaultValue: "terminal", bundle: .localizedModule) }
    static var tabSearchKindBrowser: String { String(localized: "palette.tabSearch.kind.browser", defaultValue: "browser", bundle: .localizedModule) }
}

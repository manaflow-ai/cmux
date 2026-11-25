import Foundation

/// The More (⋮) menu's own row titles, where a row reads better in the menu than its action's palette title
/// (Find… is Find in Page beside Print). Titles live in Localizable.xcstrings and ProfileActions.xcstrings.
nonisolated struct BrowserMoreMenuStrings {
    /// Find… in the More menu.
    static var findInPage: String {
        String(localized: "menu.browserMore.findInPage", defaultValue: "Find in Page", bundle: .localizedModule)
    }

    /// Screenshot Section (drag over the page) in the More menu.
    static var takeScreenshot: String {
        String(localized: "menu.browserMore.takeScreenshot", defaultValue: "Take Screenshot", bundle: .localizedModule)
    }

    /// Show Downloads… in the More menu.
    static var downloads: String { ProfileMenuSpec.text("menu.profile.downloads", "Downloads") }

    /// Show Browser History in the More menu.
    static var history: String { ProfileMenuSpec.text("menu.profile.history", "History") }
}

import CmuxBrowser
import Foundation

// App-side members of `OmnibarSuggestion` that cannot live in the package:
// `history(_:)` references the app-owned `BrowserHistoryStore.Entry`, and
// `trailingBadgeText` localizes through the app bundle's string catalog (a
// package-side `String(localized:)` would bind to the package bundle and drop
// non-English translations).
extension OmnibarSuggestion {
    static func history(_ entry: BrowserHistoryStore.Entry) -> OmnibarSuggestion {
        OmnibarSuggestion(kind: .history(url: entry.url, title: entry.title))
    }

    var trailingBadgeText: String? {
        switch kind {
        case .switchToTab:
            return String(localized: "browser.switchToTab", defaultValue: "Switch to tab")
        default:
            return nil
        }
    }
}

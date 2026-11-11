import Foundation

/// The Feed's own copy, from this module's catalog (Resources/Localizable.xcstrings).
struct FeedStrings {
    /// The catalog's bundle (tests read its translations).
    static var bundle: Bundle { .module }
    /// No Mac has answered yet (with a spinner).
    static var connecting: String {
        String(localized: "mobile.feed.connecting", defaultValue: "Connecting to your Mac…", bundle: .module)
    }
    /// No Mac answered within `FeedStore.connectDeadline`.
    static var offlineTitle: String {
        String(localized: "mobile.feed.offline.title", defaultValue: "Your Macs are offline", bundle: .module)
    }
    static var offlineBody: String {
        String(localized: "mobile.feed.offline.body", defaultValue: "Open cmux on your Mac and make sure it's online.", bundle: .module)
    }
}
